import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/upload_error_classifier.dart';

/// Отменить отправку ещё не ушедшего сообщения — ЕДИНАЯ точка для крестика на
/// пузыре и всех «Удалить» у pending/упавших (LABA-2622).
///
/// Голый `cancelSend()` только снимает пузырь: серия отправки о нём не знает,
/// заливка идёт дальше, а после паузы сети серия досылала файл — удалённое
/// сообщение воскресало у собеседника. Флаг [UploadProgressTracker.requestCancel]
/// видят все три стадии: серия (пропуск файла), HTTP-клиент (обрыв отдачи) и
/// `upload()` диалога отправки (redact опоздавшей отмены).
///
/// Байты файла SDK снимает из `sendingFilePlaceholders` только на успешном
/// пути — после отмены они висели бы в памяти `Room` до перезапуска.
/// Error-статус не ставим никогда (LABA-2239).
Future<void> cancelPendingSend(Event event) async {
  final txid = event.eventId;
  // Флаг читает только серия диалога отправки — и снимает его сама
  // (`unregister`). У txid вне серии (текст, давно упавшее событие) снять его
  // некому: `_cancelledTxids` рос бы до конца процесса.
  if (UploadProgressTracker.instance.byId(txid) != null) {
    UploadProgressTracker.instance.requestCancel(txid);
  }
  if (!event.status.isSent) {
    try {
      await event.cancelSend();
    } catch (e) {
      // Событие успело уйти или уже удалено — отменять нечего.
      Logs().v('[cancel-send] $txid: ${e.runtimeType}');
    }
  }
  event.room.sendingFilePlaceholders.remove(txid);
  event.room.sendingFileThumbnails.remove(txid);
}

/// Отмена опоздала: файл залит, событие [eventId] уже ушло (крестик нажат,
/// пока шёл `PUT /send`; на Web отдачу рвать нечем вовсе). Отзываем
/// отправленное redact-ом — иначе SDK вернёт его в ленту и собеседник его
/// получит. true — отмена была и redact запущен. Звать, пока флаг жив
/// (`unregister` его снимает).
bool revokeIfCancelledAfterSend(Room room, String txid, String eventId) {
  if (!UploadProgressTracker.instance.isCancelled(txid)) return false;
  unawaited(
    room
        .redactEvent(eventId)
        .then<void>(
          (_) {},
          onError: (Object e) =>
              Logs().w('[cancel-send] redact отменённого $eventId: $e'),
        ),
  );
  return true;
}

/// Маркер опоздавшей отмены: файл залит и событие ушло, но пользователь уже
/// нажал «отмена» — отправленное отозвано redact-ом. Серия ловит его веткой
/// `isCancelled` и пишет итог `cancelled`, а не `sent`.
class SendCancelledAfterUploadException implements Exception {
  const SendCancelledAfterUploadException();
}

/// Глобальный реестр прогресса загрузки вложений, keyed по `txid`
/// (он же `event.eventId` для pending-события до того, как сервер вернёт
/// настоящий eventId).
///
/// Используется как мост между диалогом отправки (`send_file_dialog.dart`)
/// и виджетом-bubble видео-события в ленте (`pages/chat/events/
/// video_player.dart`), который рисует прогресс поверх превью.
///
/// Источников прогресса два:
/// - **реальный** — `UploadProgressHttpClient` считает отданные байты на
///   HTTP-уровне (не-Web платформы) и зовёт [reportActiveProgress];
/// - **псевдо** — `_UploadProgressReporter` в `send_file_dialog` оценивает
///   процент по времени; нужен на Web и в фазе до начала отдачи (шифрование
///   E2EE, мелкие файлы). Как только по `txid` пришёл реальный прогресс
///   ([hasRealProgress]), псевдо-источник умолкает.
/// Этап отправки вложения. Шкала прогресса НЕ сквозная: «Сжатие 100%» и
/// «Отправка 3%» — это два разных этапа с явной подписью, а не откат числа
/// назад (иначе читается как «зависло»). Внутри этапа значение монотонно.
///
/// Этап `preparing` — окно между тапом «Отправить» и началом транскода
/// (чтение файла, HEIC, извлечение постера). Раньше это окно было немым:
/// пузыря ещё не существовало, а снекбар физически не успевал отрисоваться.
///
/// Этап `waitingNetwork` — серия отправки альбома стоит на паузе до возврата
/// связи (`AlbumSendSeries`): файл либо ещё не начат, либо упал на обрыве и
/// будет дослан самой серией. Это НЕ ошибка — повтор руками не нужен.
enum UploadPhase { preparing, compressing, uploading, waitingNetwork }

class UploadProgressTracker {
  UploadProgressTracker._();
  static final UploadProgressTracker instance = UploadProgressTracker._();

  final Map<String, ValueNotifier<double>> _notifiers = {};

  /// Этап по `txid` — ОТДЕЛЬНЫЙ канал от `_notifiers`, чтобы не менять тип
  /// публичного `byId` (его читают бабл и стражи). SDK-шный
  /// `event.fileSendingStatus` сюда не годится: его enum
  /// (`generatingThumbnail/encrypting/uploading`) не покрывает нашу фазу ДО
  /// `sendFileEvent`, а посторонняя строка в `unsigned[fileSendingStatusKey]`
  /// молча читается как null (`singleWhereOrNull` по `.name`).
  final Map<String, ValueNotifier<UploadPhase>> _phases = {};
  final Set<String> _realProgressTxids = {};
  final Set<String> _cancelledTxids = {};
  final Map<String, String> _errorReasons = {};
  // Класс последней ошибки отправки по txid (terminal/transient). Читает
  // `FailedSendRetryService`: авто-ретрай при возврате связи досылает ТОЛЬКО
  // transient, а terminal (403/413/диск) НЕ трогает (иначе retry-шторм,
  // `RL-upload-terminal-error-no-retry`). Тот же двухфазный lifecycle, что
  // `_errorReasons`: НЕ чистится в `unregister` (читается ПОСЛЕ ухода события
  // в `EventStatus.error`), снимается на следующей попытке (`register`).
  final Map<String, UploadErrorKind> _errorKinds = {};
  // txid'ы, которыми владеет идущая серия отправки (`AlbumSendSeries`): от
  // пре-эмита до конца ВСЕЙ серии. Пока txid здесь, повторять его вправе только
  // сама серия — авто-досыл при возврате связи и ручной ↻ молчат. Иначе на
  // одном txid сходились три механизма повтора и шли параллельные заливки.
  final Set<String> _ownedBySeries = {};
  String? _activeTxid;

  /// Создать notifier для указанного `txid` и положить его в реестр.
  /// Возвращает уже зарегистрированный notifier, если такой txid уже был —
  /// безопасно при повторных вызовах (например, retry на rate-limit).
  ValueNotifier<double> register(String txid) {
    // Свежая попытка по этому txid — снимаем причину прошлой ошибки, чтобы
    // не показать устаревший тултип поверх нового прогресса.
    _errorReasons.remove(txid);
    _errorKinds.remove(txid);
    _phases.putIfAbsent(
      txid,
      () => ValueNotifier<UploadPhase>(UploadPhase.preparing),
    );
    return _notifiers.putIfAbsent(txid, () => ValueNotifier<double>(0));
  }

  /// Этап по id события (`txid` до подтверждения сервером). null — отправка
  /// по этому id не идёт.
  ValueNotifier<UploadPhase>? phaseFor(String id) => _phases[id];

  /// Перевести отправку на новый этап и обнулить прогресс: шкала внутри
  /// этапа своя (см. [UploadPhase]).
  void reportPhase(String txid, UploadPhase phase) {
    final notifier = _phases[txid];
    if (notifier == null || notifier.value == phase) return;
    notifier.value = phase;
    _notifiers[txid]?.value = 0;
  }

  /// Прогресс ЭТАПА СЖАТИЯ (0..100 от `video_compress`). Отдельно от
  /// [reportActiveProgress], потому что тот принадлежит HTTP-отдаче и
  /// выставляет `_realProgressTxids` — а сжатие к отдаче отношения не имеет.
  /// Монотонность внутри этапа обязательна: назад не откатываемся.
  void reportCompressProgress(String txid, double percent) {
    if (_phases[txid]?.value != UploadPhase.compressing) return;
    final notifier = _notifiers[txid];
    if (notifier == null) return;
    final value = (percent / 100).clamp(0.0, 1.0);
    if (value < notifier.value) return;
    notifier.value = value;
  }

  /// Поднять notifier по id (`event.eventId`). Возвращает null, если
  /// загрузка не идёт.
  ValueNotifier<double>? byId(String id) => _notifiers[id];

  /// Удалить notifier (вызывается после complete/error). Disposed
  /// notifier более не используется виджетами.
  void unregister(String txid) {
    final n = _notifiers.remove(txid);
    n?.dispose();
    _phases.remove(txid)?.dispose();
    _realProgressTxids.remove(txid);
    _cancelledTxids.remove(txid);
    if (_activeTxid == txid) _activeTxid = null;
    // ВНИМАНИЕ: _errorReasons НЕ чистим здесь. `_UploadRetryOverlay`/значок
    // ошибки бабла читают причину ПОСЛЕ того, как событие ушло в
    // `EventStatus.error` (а это происходит уже после unregister в finally
    // send_file_dialog). Причина снимается на следующей попытке отправки
    // (register) — двухфазный lifecycle.
  }

  /// Сохранить человекочитаемую причину терминальной ошибки отправки по `txid`
  /// (== `event.eventId` pending-события). Читают виджеты ленты для тултипа.
  void reportError(String txid, String reason) => _errorReasons[txid] = reason;

  /// Причина последней терминальной ошибки отправки по id события, или null.
  String? errorFor(String id) => _errorReasons[id];

  /// Сохранить КЛАСС ошибки отправки (terminal/transient) по `txid`.
  /// Заполняется в точке `catchError` отправки, где исключение ещё живо
  /// (`classifyUploadError(e)`) — на самом `Event` в статусе error errcode НЕ
  /// хранится, поэтому решить «ретраить ли» позже можно только по этой записи.
  void reportErrorKind(String txid, UploadErrorKind kind) =>
      _errorKinds[txid] = kind;

  /// Класс последней ошибки отправки по id события, или null (запись не
  /// делалась — напр. сетевой обрыв ДО ответа: трактуем как transient).
  UploadErrorKind? errorKindFor(String id) => _errorKinds[id];

  /// Снять записанный класс ошибки по `txid`. Зовётся при РУЧНОМ «отправить
  /// повторно»: иначе устаревший `terminal` (напр. от 403 квоты, которую уже
  /// подняли) навсегда блокировал бы АВТО-ретрай этого события, даже если
  /// следующий сбой был сетевым (transient). После сброса kind=null → авто-
  /// ретрай снова доверяет дефолту (null=transient).
  void clearErrorKind(String txid) => _errorKinds.remove(txid);

  /// Серия отправки забирает txid'ы во владение (см. [_ownedBySeries]).
  void claimForSeries(Iterable<String> txids) {
    _ownedBySeries.addAll(txids);
    seriesChanges.value++;
  }

  /// Серия закончилась — повтор этих txid снова доступен всем механизмам.
  /// Сигнал [seriesChanges] будит оверлеи: упавшие члены сразу рисуют ↻.
  void releaseFromSeries(Iterable<String> txids) {
    _ownedBySeries.removeAll(txids);
    seriesChanges.value++;
  }

  /// Тикает на каждом захвате/релизе серии. Оверлеи пузырей и плиток
  /// пересчитывают по нему «↻ или прогресс»: статус события при релизе не
  /// меняется, и без сигнала ↻ появился бы лишь при случайной перерисовке.
  final ValueNotifier<int> seriesChanges = ValueNotifier<int>(0);

  /// Владеет ли этим id идущая серия отправки.
  bool isOwnedBySeries(String id) => _ownedBySeries.contains(id);

  /// Запросить отмену загрузки по `txid`. Флаг читает
  /// [UploadProgressHttpClient]: на ближайшем чанке тела отдача обрывается
  /// `MatrixException`-ом (терминальная ошибка для retry-цикла
  /// `room.sendFileEvent` — иначе SDK повторял бы заливку до
  /// `sendTimelineEventTimeout`). Удаление самого pending-события из ленты —
  /// отдельно — [cancelPendingSend] делает оба шага разом.
  void requestCancel(String txid) => _cancelledTxids.add(txid);

  /// Запрошена ли отмена для этого `txid`.
  bool isCancelled(String txid) => _cancelledTxids.contains(txid);

  /// Запрошена ли отмена для текущего активного txid (для HTTP-клиента,
  /// который знает только про активную отдачу).
  bool get isActiveCancelled {
    final txid = _activeTxid;
    return txid != null && _cancelledTxids.contains(txid);
  }

  /// Назначить `txid`, к которому `UploadProgressHttpClient` привяжет
  /// отчёты о реальном прогрессе. Вызывается перед началом отдачи файла.
  void markActive(String? txid) => _activeTxid = txid;

  /// Реальный прогресс отдачи тела запроса (`sent`/`total` байт) для
  /// активного txid. Источник — `UploadProgressHttpClient`.
  void reportActiveProgress(int sent, int total) {
    final txid = _activeTxid;
    if (txid == null || total <= 0) return;
    final notifier = _notifiers[txid];
    if (notifier == null) return;
    _realProgressTxids.add(txid);
    // Кап 0.99: «все байты отданы в сокет» ≠ «сервер принял и подтвердил».
    // 100% показываем только фактом исчезновения overlay-я (unregister
    // после успешного ответа сервера) — иначе пользователь видит «100%»,
    // пока загрузка на деле ещё висит.
    notifier.value = (sent / total).clamp(0.0, 0.99);
  }

  /// Пришёл ли по этому txid хотя бы один отчёт реального прогресса.
  /// Если да — псевдо-прогресс по этому txid должен замолчать.
  bool hasRealProgress(String txid) => _realProgressTxids.contains(txid);
}
