// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:http/http.dart' show ClientException;
import 'package:just_audio/just_audio.dart';
import 'package:matrix/matrix.dart';
import 'package:opus_caf_converter_dart/opus_caf_converter_dart.dart';
import 'package:path_provider/path_provider.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/utils/file_description.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/network_recovery_trigger.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/liza_app.dart';
import 'package:liza/widgets/matrix.dart';
import '../../../utils/matrix_sdk_extensions/event_extension.dart';
import '../../../utils/matrix_sdk_extensions/filtered_timeline_extension.dart';

/// Событие — воспроизводимое аудио (голосовое ИЛИ обычный аудиофайл).
///
/// Тип берём по СЫРОМУ `event.messageType`/`event.content`, НЕ через
/// `getDisplayEvent` — тот требует timeline и подменяет content последней
/// правкой (m.replace). Голосовое = маркер `org.matrix.msc3245.voice`;
/// аудиофайл (музыка) = `MessageTypes.Audio` без маркера. Оба идут через
/// [AudioPlayerWidget] и оба участвуют в цепочке автозапуска.
bool isAudioEvent(Event event) =>
    event.messageType == MessageTypes.Audio &&
    !event.redacted &&
    // В цепочку берём только доставленные события: у SENDING/ERROR нет валидного
    // вложения — авто-скачивание упёрлось бы в плейсхолдер (см.
    // [[RL-resend-missing-media-guard]]).
    event.status.isSent;

/// Резолвер «следующего подряд идущего аудио» для автозапуска цепочки.
///
/// [visibleNewestFirst] — уже отфильтрованный `filterByVisibleInGui` список
/// (newest-first, как `chat_event_list`). Брать именно его, а НЕ сырой
/// `timeline.events`: в сыром между двумя видимыми аудио лежат скрытые члены
/// галереи, edit/reaction-события и collapsed-state — они наврали бы «подряд».
///
/// Хронологически следующее сообщение = МЕНЬШИЙ индекс (newest-first). Идём от
/// `idx-1` к 0 (в будущее):
/// - аудио → возвращаем его (цепочка продолжается);
/// - `isCollapsedState` (вступления/выходы) → ПЕРЕШАГИВАЕМ (не рвёт цепочку);
/// - любое иное видимое сообщение (текст/картинка/видео/файл/стикер) → `null`
///   (строгий разрыв цепочки — требование пользователя «строго подряд»).
///
/// Чистая функция (примитивы, без плеера/клиента) — юнит-тестируема без Matrix
/// Client.
Event? nextAudioEventInChain(
  List<Event> visibleNewestFirst,
  String currentEventId,
) {
  final idx = visibleNewestFirst.indexWhere((e) => e.eventId == currentEventId);
  if (idx <= 0) return null; // не найдено или это самое новое сообщение
  for (var i = idx - 1; i >= 0; i--) {
    final candidate = visibleNewestFirst[i];
    if (isAudioEvent(candidate)) return candidate;
    if (candidate.isCollapsedState) continue; // служебное — перешагиваем
    return null; // реальное не-аудио сообщение → стоп
  }
  return null;
}

/// Дедлайн СЕТЕВОЙ фазы подготовки (скачивание+декрипт). CPU-фазу
/// (`OpusCaf().convertOpusToCaf`) НЕ оборачиваем — честно долгий transcode на
/// слабом устройстве терминалить нельзя (та же дисциплина, что у `MxcImage`, где
/// `_maybeTranscodeHeic` намеренно оставлен вне таймаута).
///
/// Это срок БЕЗ НОВЫХ БАЙТ, а не бюджет всей загрузки: каждый принятый чанк
/// перезапускает отсчёт. Бюджет на всю загрузку рубил живую докачку на слабом
/// канале: GlitchTip #2085 (2026-09-29, iPhone 3770) — голосовое 1,12 МБ при
/// ~20 КБ/с, MMR отдал его целиком за 53 с, а клиент оборвал на 60-й секунде
/// и показал ошибку. Прерванная закачка НЕ кэшируется (SDK делает `storeFile`
/// только после ПОЛНОГО тела), так что повторный тап качал бы всё заново.
///
/// Собственный дедлайн нужен потому, что SDK-таймаут тут не страхует: Liza
/// поднимает `defaultNetworkRequestTimeout` до 30 минут
/// (`client_manager.dart`) — «тлеющее» соединение без байтов живёт часами.
/// Порог тот же, что у видео (`_downloadIdleTimeout`). После последнего чанка в
/// то же окно укладываются декрипт и `storeFile` SDK — это секунды.
const Duration kAudioPrepareNetworkTimeout = Duration(seconds: 60);

/// Сколько после возврата из фона сбой ещё списываем на заморозку: на `resumed`
/// `MatrixState._refreshHttpClients` force-закрывает прежний HTTP-клиент, и
/// загрузка, пережившая сон, падает `ClientException` в первые же миллисекунды.
const Duration kAudioPrepareResumeGrace = Duration(seconds: 5);

/// Сбой подготовки вызван заморозкой мобильного процесса ОС, а не сетью.
///
/// iOS/Android усыпляют процесс с загрузкой в полёте; таймер дедлайна
/// выстреливает при первом же пробуждении, в том числе фоновом. Инцидент
/// 2026-09-15 (GlitchTip #2025, `mime=video/mp4` — это m4a 26 МБ): уход в фон в
/// 05:51, `prepare-timeout` в 06:02 с `in_foreground=false`, хотя MMR честно
/// отдавал файл, а в 07:13 тот же файл скачался за 4,4 с. Вызывающие НЕ шлют
/// алёрт и НЕ показывают ошибку: SnackBar, поставленный в фоне, всплыл бы при
/// возврате с ошибкой, которой пользователь не видел.
class AudioPrepareSuspendedException implements Exception {
  final Object cause;
  const AudioPrepareSuspendedException(this.cause);

  @override
  String toString() => 'AudioPrepareSuspendedException: $cause';
}

/// Дедлайн простоя (перезапуск на каждом чанке) по времени ОТКРЫТОГО
/// приложения + ответ «сбой объясняется сном?». Живёт на одну подготовку (обе
/// попытки). Без [suspendable] (desktop) lifecycle не слушает.
class _ForegroundDeadline {
  _ForegroundDeadline(this._resumeGrace, {required bool suspendable})
    : _suspendable = suspendable,
      _suspended =
          suspendable &&
          isSuspendingLifecycleState(WidgetsBinding.instance.lifecycleState) {
    if (suspendable) {
      _listener = AppLifecycleListener(onStateChange: _onStateChange);
    }
  }

  final Duration _resumeGrace;
  final bool _suspendable;
  AppLifecycleListener? _listener;
  bool _suspended;
  bool _justResumed = false;
  Timer? _grace;
  Timer? _timer;
  Duration _timeout = Duration.zero;
  void Function()? _onExpire;

  Future<T> guard<T>(Future<T> future, Duration timeout) {
    final result = Completer<T>();
    _timeout = timeout;
    _onExpire = () {
      if (!result.isCompleted) {
        result.completeError(TimeoutException('audio prepare', timeout));
      }
    };
    _restart();
    unawaited(
      future.then(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object e, StackTrace s) {
          if (!result.isCompleted) result.completeError(e, s);
        },
      ),
    );
    return result.future.whenComplete(() {
      _timer?.cancel();
      _onExpire = null;
    });
  }

  /// Пришли байты — канал жив, срок заново.
  void touch() => _restart();

  void _restart() {
    _timer?.cancel();
    final onExpire = _onExpire;
    if (onExpire != null) _timer = Timer(_timeout, onExpire);
  }

  void _onStateChange(AppLifecycleState state) {
    final suspended = isSuspendingLifecycleState(state);
    if (suspended == _suspended) return;
    _suspended = suspended;
    _grace?.cancel();
    _justResumed = !suspended;
    if (suspended) return;
    _grace = Timer(_resumeGrace, () => _justResumed = false);
    // Отсчёт заново с возврата. Таймер НЕ останавливаем на уходе в фон: цепочка
    // автозапуска готовит трек и при заблокированном экране, и там дедлайн
    // обязан её остановить. Но сон не должен съедать срок, а честное зависание
    // ПОСЛЕ возврата обязано дать алёрт — иначе мимолётный фон в начале глушил
    // бы сигнал о реальном сбое на глазах у пользователя.
    _restart();
  }

  bool get failureExplainedBySuspension =>
      _suspendable &&
      (_suspended ||
          _justResumed ||
          isSuspendingLifecycleState(WidgetsBinding.instance.lifecycleState));

  void dispose() {
    _listener?.dispose();
    _timer?.cancel();
    _grace?.cancel();
  }
}

/// [attempt] под дедлайном [timeout] с РОВНО одним повтором транспортной ошибки.
///
/// Повтор — только на [ClientException] (обрыв сокета), и только один: пул
/// `CustomHttpClient` держит `idleTimeout = 15 s`, поэтому первый запрос после
/// возврата из фона регулярно уходит в переиспользованный мёртвый keep-alive
/// сокет и падает с «Connection closed before full header was received», а
/// `RetryClient(retries: 2)` идёт с дефолтным `whenError: false` и транспортные
/// ошибки НЕ ретраит вовсе. Пользователь был вынужден тапать второй раз руками
/// (инцидент 2026-09-09).
///
/// На HTTP-коды повтор НЕ распространяется — там действует
/// [[RL-media-http-error-gate]] («ошибка = стоп, без retry-шторма»), и лишние
/// попытки жгли бы одноразовые бюджеты самолечения в
/// `downloadAndDecryptAttachmentHealed`.
///
/// [timeout] — срок простоя: [attempt] получает `onBytes` и зовёт его на каждом
/// принятом чанке, отсчёт начинается заново (см. [kAudioPrepareNetworkTimeout]).
///
/// На mobile ([suspendable] по умолчанию) дедлайн считает время открытого
/// приложения, а итоговый сетевой/таймаут-сбой, всплывший в фоне или в первые
/// [resumeGrace] после возврата, поднимается как
/// [AudioPrepareSuspendedException]. HTTP-коды и декрипт так не глушатся. На
/// desktop свёрнутое окно не замораживается — lifecycle не учитывается.
@visibleForTesting
Future<T> withForegroundDeadline<T>(
  Future<T> Function(void Function() onBytes) attempt,
  Duration timeout, {
  bool? suspendable,
  Duration resumeGrace = kAudioPrepareResumeGrace,
}) async {
  final deadline = _ForegroundDeadline(
    resumeGrace,
    suspendable: suspendable ?? PlatformInfos.isMobile,
  );
  try {
    return await _withSingleTransportRetry(
      () => deadline.guard(attempt(deadline.touch), timeout),
    );
  } catch (e) {
    final transport = const {
      'timeout',
      'network',
    }.contains(mediaFailureKind(e));
    if (transport && deadline.failureExplainedBySuspension) {
      throw AudioPrepareSuspendedException(e);
    }
    rethrow;
  } finally {
    deadline.dispose();
  }
}

Future<T> _withSingleTransportRetry<T>(Future<T> Function() attempt) async {
  try {
    return await attempt();
  } on ClientException catch (e) {
    Logs().w('[AudioPrepare] transport error, single retry', e);
    return await attempt();
  }
}

Future<MatrixFile> _downloadAudioAttachment(
  Event event,
  int? fileSize,
  void Function(double progress)? onProgress,
) {
  return withForegroundDeadline(
    (onBytes) => event.downloadAndDecryptAttachmentHealed(
      onDownloadProgress: (received) {
        onBytes();
        if (fileSize != null && fileSize > 0) {
          onProgress?.call(received / fileSize);
        }
      },
    ),
    kAudioPrepareNetworkTimeout,
  );
}

/// Скачивает+расшифровывает аудио-вложение [event] и готовит локальный файл к
/// воспроизведению. На darwin (iOS/macOS) переупаковывает ogg/opus в CAF
/// (AVFoundation не декодирует ogg). Возвращает `file` (native) ИЛИ `matrixFile`
/// для стрим-источника (Web, где нет файловой системы).
///
/// Вынесено из `AudioPlayerState._downloadAndPlay`, чтобы ОДИН и тот же путь
/// подготовки использовали и ручной первый тап (с прогрессом), и автозапуск
/// следующего трека (тихо, без BuildContext). [onProgress] — опционально, для
/// индикатора загрузки смонтированного пузыря.
Future<({File? file, MatrixFile matrixFile})> prepareAudioPlaybackFile(
  Event event, {
  void Function(double progress)? onProgress,
}) async {
  final fileSize = event.content
      .tryGetMap<String, dynamic>('info')
      ?.tryGet<int>('size');
  final matrixFile = await _downloadAudioAttachment(
    event,
    fileSize,
    onProgress,
  );

  if (kIsWeb) return (file: null, matrixFile: matrixFile);

  final tempDir = await getTemporaryDirectory();
  final fileName = Uri.encodeComponent(
    event.attachmentOrThumbnailMxcUrl()!.pathSegments.last,
  );
  var file = File('${tempDir.path}/${fileName}_${matrixFile.name}');
  await file.writeAsBytes(matrixFile.bytes);

  // На darwin just_audio играет через AVFoundation, который НЕ декодирует
  // ogg/opus. Переупаковываем opus в CAF-контейнер (входящие голосовые с
  // Android/Linux).
  if ((Platform.isIOS || Platform.isMacOS) &&
      matrixFile.mimeType.toLowerCase() == 'audio/ogg') {
    Logs().v('Convert ogg audio file for darwin (AVFoundation)...');
    final convertedFile = File('${file.path}.caf');
    if (await convertedFile.exists() == false) {
      OpusCaf().convertOpusToCaf(file.path, convertedFile.path);
    }
    file = convertedFile;
  }

  return (file: file, matrixFile: matrixFile);
}

/// To use a MatrixFile as an AudioSource for the just_audio package.
class MatrixFileAudioSource extends StreamAudioSource {
  final MatrixFile file;

  MatrixFileAudioSource(this.file);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= file.bytes.length;
    return StreamAudioResponse(
      sourceLength: file.bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(file.bytes.sublist(start, end)),
      contentType: file.mimeType,
    );
  }
}

/// Низкокардинальный контекст аудио-сигнала мониторинга (kind/mime/size-бакет/
/// e2ee). БЕЗ mxc/пути/токена (пин `RL-mediadiag-no-secret`).
///
/// Порядок ключей = порядок УБЫВАНИЯ диагностической
/// ценности: `Monitoring.buildAlertTitle` отбрасывает хвост, когда title не
/// влезает в 99 символов GlitchTip'а, — значит `kind` (единственное поле,
/// отвечающее «почему») обязан идти ПЕРВЫМ, а `e2ee` (реже всего решает) —
/// последним. [error] передают вызывающие стороны сбоя ПОЛУЧЕНИЯ вложения
/// (скачать+расшифровать); для сбоев плеера его нет — там `kind` не пишем.
/// При `kind=other` сразу за ним идёт `err` — тип исключения
/// ([mediaFailureErrorType]), иначе класс `other` не отвечает на «почему».
/// [playerError] — текст `PlayerException` сбоя самого плеера; в контекст идёт
/// только его класс ([audioPlayerErrorClass]) — первым полем, по той же причине.
Map<String, String> audioIssueContext(
  Event event, {
  Object? error,
  String? playerError,
}) {
  // Оба источника пишут в `err` — вместе второй молча перезаписал бы первый.
  assert(error == null || playerError == null);
  final info = event.content.tryGetMap<String, dynamic>('info');
  final mime = info?.tryGet<String>('mimetype');
  final kind = error == null ? null : mediaFailureKind(error);
  return {
    if (playerError != null) 'err': audioPlayerErrorClass(playerError),
    if (kind != null) 'kind': kind,
    if (kind == 'other') 'err': mediaFailureErrorType(error!),
    if (mime != null) 'mime': mime,
    'size': audioSizeBucket(info?.tryGet<int>('size')),
    'e2ee': '${event.isAttachmentEncrypted}',
  };
}

/// Класс ошибки плеера из текста `PlayerException` — закрытый перечень.
///
/// На Windows/Linux (`just_audio_media_kit`) `errorStream` — это любая строка
/// уровня `error` из лога mpv (префиксы `ad`/`vd`/`cplayer`/`stream`/`file`/
/// `ffmpeg tcp:`), в том числе нефатальная: один битый кадр mpv пропускает и
/// играет дальше. GlitchTip #2081 (2026-09-27, Windows 3764) пришёл как
/// `reason=playback-error` без текста — отличить «файл не открылся» от «кадр не
/// декодировался» было нечем. Сам текст в title не кладём: в нём путь к файлу с
/// именем пользователя Windows и URL (пин `RL-mediadiag-no-secret`).
String audioPlayerErrorClass(String? message) {
  final m = (message ?? '').toLowerCase();
  if (m.trim().isEmpty) return 'none';
  if (m.startsWith('tcp:') ||
      m.contains('connection') ||
      m.contains('http error') ||
      m.contains('network')) {
    return 'network';
  }
  if (m.contains('recognize file format') || m.contains('unrecognized')) {
    return 'format';
  }
  if (m.contains('codec')) return 'codec';
  if (m.contains('decod')) return 'decode';
  if (m.contains('failed to open') ||
      m.contains('no such file') ||
      m.contains('cannot open') ||
      m.contains('could not open')) {
    return 'open';
  }
  return 'other';
}

/// Грубый бакет размера — низкая кардинальность для дедупа notifier'а (сырой
/// размер расклеил бы message-issue в GlitchTip).
String audioSizeBucket(int? bytes) {
  if (bytes == null) return 'unknown';
  final mb = bytes / (1024 * 1024);
  if (mb < 1) return '<1mb';
  if (mb < 5) return '1-5mb';
  if (mb < 20) return '5-20mb';
  return '>20mb';
}

typedef NextAudioResolver = Event? Function(String currentEventId);

/// Автозапуск цепочки голосовых/аудио: по завершению одного аудио автоматически
/// стартует следующее ПОДРЯД идущее (Liza-паритет).
///
/// Живёт в [MatrixState] рядом с глобальным плеером
/// (`audioPlayer`/`voiceMessageEventId`), а не в виджете пузыря — плеер
/// переживает `dispose` пузыря (скролл/banner-режим), значит и подписка на его
/// завершение обязана жить вне виджета. Резолв «следующего» делегируется
/// `ChatController` (он знает `timeline`+`activeThreadId`) через
/// [registerResolver]; вне открытого чата резолвера нет → цепочка обрывается.
///
/// Дизайн: `docs/superpowers/specs/2026-08-20-voice-message-autoplay-chain-design.md`.
class AudioAutoPlayService {
  final MatrixState _matrix;
  AudioAutoPlayService(this._matrix);

  /// Резолвер «следующего аудио» по roomId (ключ — комната доигрываемого трека,
  /// не «последний открытый чат»). Один активный `ChatController` на комнату,
  /// поэтому Map, а не список.
  final Map<String, NextAudioResolver> _resolvers = {};

  StreamSubscription<PlayerState>? _completionSub;

  /// Подписка на `errorStream` активного плеера — ЕДИНСТВЕННЫЙ владелец сигнала
  /// об ошибке ВОСПРОИЗВЕДЕНИЯ (плеер глобальный в MatrixState, переживает
  /// виджет пузыря → подписка обязана жить здесь, а не в `AudioPlayerState`).
  /// Пересоздаётся на каждый `onPlaybackStarted`, снимается в `detach()`/`dispose()`.
  StreamSubscription<PlayerException>? _errorSub;

  /// Поколение авто-подготовки. Каждый `_playEvent` захватывает своё значение;
  /// любая отмена ([cancelAdvance]/[detach]/[dispose]) инкрементирует счётчик, и
  /// in-flight подготовка после ОЧЕРЕДНОГО await видит расхождение, гасит своё и
  /// выходит, НЕ трогая глобальный плеер.
  ///
  /// Заменил прежний `bool _cancelled`, который был TOCTOU: `onPlaybackStarted`
  /// первой строкой делал `_cancelled = false`, поэтому ручной старт СБРАСЫВАЛ
  /// отмену, выставленную для чужой in-flight подготовки, и та доезжала до конца,
  /// затирая только что запущенный пользователем плеер. Пока тап отбивался
  /// `isAdvancing`, случай был недостижим — и становится достижимым ровно с
  /// введением «тап отменяет подготовку», поэтому флаг убран, а не доработан.
  int _advanceGeneration = 0;

  /// Future текущей авто-подготовки. Ручной тап ОБЯЗАН его дождаться, прежде чем
  /// заводить свой плеер: отмена лишь помечает поколение, а фактический
  /// `dispose()` нативного плеера происходит внутри `_playEvent`. Без ожидания
  /// `dispose` старого per-player MethodChannel наложился бы на `init` нового —
  /// darwin `MissingPluginException` (баг #1).
  Future<void>? _advanceInFlight;

  /// Комната, для которой идёт авто-подготовка. Нужна, чтобы уход из ОДНОГО чата
  /// не рвал цепочку, играющую в другой комнате (двухпанельный режим).
  String? _advancingRoomId;

  /// Сервис-уровневый re-entrancy guard: авто-переход дёргает
  /// stop→dispose→create вплотную по completion; без него быстрый автопереход
  /// создаст два плеера → darwin `MissingPluginException` (per-player
  /// MethodChannel, баг #1).
  ///
  /// ⚠️ Это гард СЕРИАЛИЗАЦИИ, а НЕ игнорирования пользовательского ввода. Тап по
  /// аудио во время подготовки больше НЕ отбрасывается по нему (см.
  /// [cancelAdvance] и `AudioPlayerState._onButtonTap`): раньше он глухо гасил
  /// тапы по ЛЮБОМУ аудио в ЛЮБОЙ комнате — флаг один на сервис, а резолверы
  /// per-room.
  bool _autoAdvanceInProgress = false;

  /// Идёт ли сейчас авто-подготовка следующего трека.
  bool get isAdvancing => _autoAdvanceInProgress;

  /// Отменяет in-flight авто-подготовку и возвращает future, по завершении
  /// которого нативный плеер прошлой подготовки уже освобождён — только после
  /// него безопасно создавать новый (darwin per-player канал).
  ///
  /// [roomId] сужает отмену до конкретной комнаты (уход из чата); без него
  /// отменяется любая подготовка (явное действие пользователя).
  Future<void> cancelAdvance({String? roomId}) {
    if (roomId != null && _advancingRoomId != roomId) return Future.value();
    _advanceGeneration++;
    final inFlight = _advanceInFlight;
    if (inFlight == null) {
      // Некому снять фазу в своём `finally` — снимаем сами, иначе пузырь остался
      // бы со спиннером после отмены.
      _matrix.preparingAudio.value = null;
      return Future.value();
    }
    return inFlight;
  }

  /// Регистрирует резолвер «следующего аудио» для комнаты [roomId]. Вызывает
  /// `ChatController` при инициализации; резолвер лениво читает актуальные
  /// `timeline`/`activeThreadId`.
  void registerResolver(String roomId, NextAudioResolver resolver) =>
      _resolvers[roomId] = resolver;

  /// Снимает резолвер комнаты И отменяет её in-flight авто-подготовку.
  ///
  /// Отмена вешается именно на lifecycle ЧАТА, а не пузыря: `AudioPlayerState`
  /// диспоузится ещё и при СКРОЛЛЕ (рециклинг списка), и отмена оттуда рвала бы
  /// цепочку при прокрутке. Раньше отмены при уходе из чата не было вовсе:
  /// `AudioPlayerState.dispose` детачит только при совпадении
  /// `voiceMessageEventId` со своим eventId, а в окне подготовки он был `null` —
  /// поэтому подготовленный трек стартовал уже вне чата (жалоба 2026-09-09).
  void unregisterResolver(String roomId) {
    _resolvers.remove(roomId);
    unawaited(cancelAdvance(roomId: roomId));
  }

  /// Подключает one-shot слушатель завершения к [player], играющему [event].
  /// Вызывается и ручным первым тапом, и авто-переходом — так цепочка тянется
  /// сама. `.take(1)` обязателен: `ProcessingState.completed` остаётся
  /// `completed` до следующего `seek`/`setSource`, а `.distinct()` не спасает
  /// нового подписчика (у него нет предыдущего значения) — повторных
  /// срабатываний быть не должно.
  void onPlaybackStarted(AudioPlayer player, Event event) {
    _completionSub?.cancel();
    _completionSub = player.playerStateStream
        .where((state) => state.processingState == ProcessingState.completed)
        .take(1)
        .listen((_) => _onCompleted(player, event));
    // errorStream just_audio эмитит PlayerException при рантайм-сбое декодера
    // в СЕРЕДИНЕ трека (то, что синхронный try/catch setSource не ловит).
    // НЕ `.take(1)` — плеер может эмитить несколько ошибок; лавину гасит
    // per-reason троттл в Monitoring.reportAudioIssue.
    _errorSub?.cancel();
    _errorSub = player.errorStream.listen(
      (e) => _onPlaybackError(player, event, e),
    );
  }

  /// Сигнал об ошибке воспроизведения. identity-guard (как в `_onCompleted`)
  /// отсекает ОСИРОТЕВШИЙ плеер: при авто-переходе `stop→dispose→new` старый
  /// плеер на darwin может эмитить «ошибку» на teardown — сигналить по ней
  /// нельзя (ложный флуд). Сигналим только пока плеер — текущий активный.
  void _onPlaybackError(AudioPlayer player, Event event, PlayerException e) {
    if (!identical(_matrix.audioPlayer, player)) return;
    Logs().w('[AudioAutoPlay] playback error', e);
    Monitoring.reportAudioIssue(
      prefix: Monitoring.audioFailurePrefix,
      reason: 'playback-error',
      host: event.room.client.homeserver?.host,
      context: audioIssueContext(event, playerError: e.message),
    );
  }

  /// Снимает подписку И отменяет in-flight авто-подготовку (ручная остановка/
  /// dispose пузыря/закрытие banner'а/уход из чата) — чтобы уже начатый
  /// `_playEvent` не завёл следующий трек поверх явного действия пользователя.
  void detach() {
    _advanceGeneration++;
    _completionSub?.cancel();
    _completionSub = null;
    _errorSub?.cancel();
    _errorSub = null;
  }

  Future<void> _onCompleted(AudioPlayer player, Event event) async {
    _completionSub = null;
    Logs().v('[AudioAutoPlay] completed ${event.eventId}');
    // identity-guard: за время воспроизведения пользователь мог тапнуть паузу,
    // выбрать другое аудио или перемотать — тогда активный плеер/событие уже
    // не наши, и авто-переход перебил бы осознанное действие.
    if (!identical(_matrix.audioPlayer, player)) {
      Logs().v('[AudioAutoPlay] skip: player changed');
      return;
    }
    if (_matrix.voiceMessageEventId.value != event.eventId) {
      Logs().v('[AudioAutoPlay] skip: eventId changed');
      return;
    }
    // loop-guard: битый/недозагруженный трек имеет duration==null и
    // `isAtEndPosition` считает его «сразу в конце» → без этой проверки цепочка
    // зациклится на нём. Авто-переходим только после реально проигранного трека.
    if (player.duration == null) {
      Logs().v('[AudioAutoPlay] skip: duration==null');
      return;
    }

    final resolver = _resolvers[event.room.id];
    if (resolver == null) {
      Logs().v('[AudioAutoPlay] skip: no resolver (chat closed)');
      return; // чат закрыт (banner-режим) → обрыв цепочки
    }
    final next = resolver(event.eventId);
    if (next == null) {
      Logs().v('[AudioAutoPlay] chain end: no next audio');
      return; // следующее не-аудио / конец ленты / вне окна
    }
    Logs().v('[AudioAutoPlay] advancing ${event.eventId} -> ${next.eventId}');
    await _playEvent(next);
  }

  Future<void> _playEvent(Event event) async {
    if (_autoAdvanceInProgress) return;
    _autoAdvanceInProgress = true;
    final gen = ++_advanceGeneration;
    _advancingRoomId = event.room.id;
    final done = Completer<void>();
    _advanceInFlight = done.future;
    // Guard держим ТОЛЬКО на время setup (скачивание+создание плеера), а НЕ на
    // всю длину трека: just_audio `play()` резолвится лишь В КОНЦЕ
    // воспроизведения. Если ждать его под guard'ом — следующий автопереход
    // (completion этого трека) упрётся в `_autoAdvanceInProgress` и НЕ сработает
    // → цепочка встаёт после одного шага (баг: «после второго не играет»).
    AudioPlayer? started;
    try {
      // ⚠️ ПОРЯДОК КРИТИЧЕН (фикс «мёртвого окна», инцидент 2026-09-09).
      // СНАЧАЛА готовим файл, и только ПОТОМ трогаем глобальное состояние
      // плеера. Раньше было наоборот: `voiceMessageEventId`/`audioPlayer`
      // обнулялись ПЕРЕД скачиванием, и на всё его время (сеть + CPU + произвол
      // ОС при уходе в фон — у пользователя вышло ≈4,5 минуты) ни один пузырь не
      // показывал ни спиннер, ни pause, а тапы глухо отбивались по `isAdvancing`.
      // Теперь окно «нет активного плеера» сжато до [dispose старого + create
      // нового] ≈ миллисекунды.
      _matrix.preparingAudio.value = (eventId: event.eventId, progress: null);

      final ({File? file, MatrixFile matrixFile}) prepared;
      try {
        prepared = await prepareAudioPlaybackFile(
          event,
          onProgress: (progress) {
            if (gen != _advanceGeneration) return;
            _matrix.preparingAudio.value = (
              eventId: event.eventId,
              progress: progress < 1 ? progress : null,
            );
          },
        );
      } catch (e, s) {
        // Ошибка скачивания следующего (404/битое тело/декрипт/таймаут)
        // ОСТАНАВЛИВАЕТ цепочку — без retry-шторма и без перехода «через одно»
        // ([[RL-media-http-error-gate]]). Сообщаем через глобальный messenger,
        // BuildContext пузыря может быть уже размонтирован.
        if (gen != _advanceGeneration) return; // отменили — молчим
        if (e is AudioPrepareSuspendedException) {
          // Процесс спал — не авария: цепочку молча останавливаем.
          Logs().i(
            '[AudioAutoPlay] prepare next: deadline hit while suspended',
          );
          return;
        }
        Logs().w('[AudioAutoPlay] prepare next failed', e, s);
        // Незалитая копия без байтов — не сбой (#2080), см. audio_player.
        if (!event.isPendingMediaWithoutBytes) {
          Monitoring.reportAudioIssue(
            prefix: Monitoring.audioFailurePrefix,
            reason: e is TimeoutException
                ? 'prepare-timeout'
                : 'autoplay-next-fail',
            host: event.room.client.homeserver?.host,
            context: audioIssueContext(event, error: e),
          );
        }
        _showError(e);
        return;
      }
      if (gen != _advanceGeneration) return; // отменили за время подготовки

      // Критическая секция: гасим прежний плеер и заводим новый. НОВЫЙ eventId
      // выставим ПОСЛЕ создания плеера — иначе ValueListenableBuilder перерисует
      // пузырь, пока `matrix.audioPlayer` ещё null (поле, а не нотифаер, повторно
      // не уведомляет), StreamBuilder подпишется на null: звук идёт, а UI пузыря
      // стоит на play (баг: «эффект воспроизведения второго не отображается»).
      _matrix.voiceMessageEventId.value = null;
      final previous = _matrix.audioPlayer;
      _matrix.audioPlayer = null;
      if (previous != null) {
        // Строго await: наложение dispose старого per-player канала на init
        // нового роняет play с MissingPluginException (darwin, баг #1).
        await previous.stop();
        await previous.dispose();
      }
      if (gen != _advanceGeneration) return;

      final player = _matrix.audioPlayer = AudioPlayer();
      try {
        if (prepared.file != null) {
          await player.setFilePath(prepared.file!.path);
        } else {
          await player.setAudioSource(
            MatrixFileAudioSource(prepared.matrixFile),
          );
        }
      } catch (e, s) {
        Logs().w('[AudioAutoPlay] setSource next failed', e, s);
        _matrix.audioPlayer = null;
        await player.dispose();
        _matrix.voiceMessageEventId.value = null;
        Monitoring.reportAudioIssue(
          prefix: Monitoring.audioFailurePrefix,
          reason: 'autoplay-next-fail',
          host: event.room.client.homeserver?.host,
          context: audioIssueContext(
            event,
            playerError: e is PlayerException ? e.message : null,
          ),
        );
        _showError(e);
        return;
      }

      // Скорость переносится: та же глобальная настройка, что и при ручном
      // старте (требование пользователя №3).
      final speed = AppSettings.audioPlaybackSpeed.value;
      if (speed != 1.0) await player.setSpeed(speed);

      // Отменили за время setSource/setSpeed — гасим только что созданный плеер,
      // чтобы он не заиграл поверх явного действия и не утёк.
      if (gen != _advanceGeneration) {
        _matrix.audioPlayer = null;
        _matrix.voiceMessageEventId.value = null;
        await player.dispose();
        return;
      }

      // Тянем цепочку дальше: следующее completion → следующий трек.
      onPlaybackStarted(player, event);
      // ТЕПЕРЬ уведомляем — пузырь перерисуется, когда `matrix.audioPlayer` уже
      // указывает на новый плеер, и подхватит его позицию/иконку паузы.
      _matrix.voiceMessageEventId.value = event.eventId;
      started = player;
    } finally {
      _autoAdvanceInProgress = false;
      // Фазу подготовки снимаем на ВСЕХ выходах (успех, ошибка, таймаут,
      // отмена) — иначе пузырь останется со спиннером навсегда. Чужую фазу не
      // трогаем: пока мы разматывались, отменивший нас тап мог начать свою.
      if (_matrix.preparingAudio.value?.eventId == event.eventId) {
        _matrix.preparingAudio.value = null;
      }
      if (_advancingRoomId == event.room.id) _advancingRoomId = null;
      done.complete();
    }
    // play() запускаем ПОСЛЕ снятия guard'а и БЕЗ ожидания конца трека — иначе
    // completion не смог бы запустить следующий (см. коммент выше). Сюда
    // доходим только при успешном setup без отмены (иначе ранний return),
    // поэтому started непустой.
    unawaited(
      started.play().onError((e, s) {
        Logs().w('[AudioAutoPlay] play next failed', e, s);
      }),
    );
  }

  void _showError(Object error) {
    final context = LizaApp.router.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toLocalizedString(context))));
  }

  void dispose() {
    _advanceGeneration++; // прервать in-flight авто-подготовку при logout
    _advancingRoomId = null;
    _matrix.preparingAudio.value = null;
    _completionSub?.cancel();
    _completionSub = null;
    _errorSub?.cancel();
    _errorSub = null;
    _resolvers.clear();
  }
}
