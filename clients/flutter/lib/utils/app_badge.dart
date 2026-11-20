import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_new_badger/flutter_new_badger.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/push_contract_session.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/unseen_messages.dart';

/// Бейдж иконки приложения — единая точка для [BackgroundPush] и push_helper.
///
/// Бейдж — best-effort фича: его ошибки не должны становиться событиями
/// мониторинга (отказ юзера от бейджей — состояние, а не баг).
abstract final class AppBadge {
  /// Платформа отвергла обновление бейджа (юзер запретил бейджи в iOS,
  /// лаунчер Android без поддержки). Глушим вызовы до следующего resume:
  /// смена notification-тоггла в Настройках iOS НЕ перезапускает процесс,
  /// поэтому флаг обязан сбрасываться (см. didChangeAppLifecycleState).
  static Object? _binding;
  static Client? Function()? _primary;
  static Future<void>? _writes;
  static int _bindingEpoch = 0;
  static const nativeDeadline = Duration(seconds: 2);

  static void bindPrimary(Object owner, Client? Function() primary) {
    _bindingEpoch++;
    _writes = null;
    _binding = owner;
    _primary = primary;
  }

  static void unbindPrimary(Object owner) {
    if (!identical(owner, _binding)) return;
    _bindingEpoch++;
    _writes = null;
    _primary = null;
    _binding = null;
  }

  static int? primaryUnreadCount(Client source) =>
      identical(_primary?.call(), source) ? visibleUnreadCount(source) : null;

  static bool _denied = false;
  static bool _deniedLogged = false;

  /// Нативный запрос notification-разрешений (apns) уже выполнен. До него
  /// бейджер на iOS звать нельзя: flutter_new_badger при notDetermined сам
  /// показывает системный диалог с единственной опцией .badge — отказ в нём
  /// гасит весь notification-authorization (alert/sound) до ручного
  /// включения в Настройках.
  static bool _permissionFlowDone = false;

  static void markPermissionRequested() => _permissionFlowDone = true;

  static void resetDenied() => _denied = false;

  /// Бейдж запрещён/недоступен на платформе (юзер отключил значки). Read-back
  /// рендера бейджа при взведённом латче не измеряет расхождение (setBadge был
  /// проглушён) — вызывающая сторона мониторинга должна пропускать этот случай.
  static bool get isDenied => _denied;

  /// Предикат «запись бейджа будет ПРОГЛОЧЕНА» — ровно те же два условия, по
  /// которым выходит [trySet]. Вынесен параметрами (а не читает статику), чтобы
  /// проверяться на host-VM: ветка iOS-латча иначе не покрывается вовсе —
  /// host-тесты идут на macOS, где `Platform.isIOS == false`.
  static bool writeSuppressed({
    required bool denied,
    required bool isIOS,
    required bool permissionFlowDone,
  }) => denied || (isIOS && !permissionFlowDone);

  /// Запись бейджа ПРОГЛОЧЕНА, а не выполнена: либо платформа отказала
  /// (`_denied`), либо мы ещё до permission-латча на iOS. Второй случай важен
  /// отдельно: `trySet` из-под него выходит молча, `_denied` при этом остаётся
  /// `false`, поэтому read-back сравнивал бы Dart-счёт с числом, оставленным NSE,
  /// — гарантированный ложняк на холодном старте до `markPermissionRequested()`.
  static bool get isWriteSuppressed => writeSuppressed(
    denied: _denied,
    isIOS: !kIsWeb && Platform.isIOS,
    permissionFlowDone: _permissionFlowDone,
  );

  /// Монотонный счётчик ФАКТИЧЕСКИ выполненных записей бейджа. Нужен для
  /// честного read-back при обновлениях из sync, resume и push_helper. Пока измеряющая
  /// сторона ждёт `getBadge()`, любой из них может переписать бейдж, и read-back
  /// увидит ЧУЖОЕ число. Сверять `writeSeq` до и после — значит отличить «бейдж
  /// залип» (seq не менялся, значение всё равно другое) от «нас обогнали»
  /// (seq вырос). Без этого детектор рапортовал соседние целые (delta==1 в 87%
  /// случаев, двунаправленно у одного юзера) — то есть измерял собственную гонку.
  static int get writeSeq => _writeSeq;
  static int _writeSeq = 0;
  static int? _lastJournaledCount;

  /// Канал к нативному APNs-плагину (iOS `ApnsPushPlugin` / macOS
  /// `MacApnsPushPlugin`) — по нему число видимых непрочитанных уезжает в App
  /// Group, откуда его читают NSE (закрытое приложение) и `AppDelegate`
  /// (macOS foreground-banner). Это единственный способ дать нативному
  /// фон-пути КЛИЕНТСКОЕ число вместо сырого серверного `counts.unread`.
  static const MethodChannel _apnsChannel = MethodChannel(
    'com.prodamus.laba.liza/apns',
  );

  /// Клиент-авторитетное число для бейджа: видимые в списке чатов
  /// непрочитанные/приглашённые комнаты. `null`, если клиент ещё не синкался
  /// (`prevBatch == null`) — тогда `client.rooms` неполон, и считать нельзя
  /// (иначе занизим до нуля). Это ЕДИНАЯ формула для всех поверхностей бейджа
  /// (иконка, `number` Android-нотификации, App Group для NSE).
  static final _readyRooms = Expando<Future>();
  static final _loadingRooms = Expando<Future>();

  static int? visibleUnreadCount(Client client) {
    if (client.prevBatch == null) return null;
    final loading = client.roomsLoading;
    if (client.rooms.isEmpty &&
        loading != null &&
        !identical(_readyRooms[client], loading)) {
      if (!identical(_loadingRooms[client], loading)) {
        _loadingRooms[client] = loading;
        loading.then<void>((_) {
          if (identical(client.roomsLoading, loading)) {
            _readyRooms[client] = loading;
          }
        }, onError: (Object _) {});
      }
      return null;
    }
    return client.rooms.where((room) => room.countsTowardAppBadge).length;
  }

  /// Единый источник истины для числа на бейдже: видимые в списке чатов
  /// непрочитанные/приглашённые комнаты (скрытые stories/topology-hidden не
  /// в счёт — их нельзя открыть и прочитать). Перебивает серверный
  /// `counts.unread` из payload пуша, который про клиентскую топологию не знает.
  /// На несинканном клиенте `client.rooms` пуст — пропускаем, чтобы не затереть
  /// бейдж нулём из фонового изолята без состояния.
  static Future<void> refreshFrom(
    Client client, {
    Client? Function()? primary,
  }) async {
    // Порядок «квитанция vs lastEvent» для комнат с частичной квитанцией
    // считается из локальной БД асинхронно — ДО подсчёта, иначе
    // `countsTowardAppBadge` ушёл бы в ts-фолбэк SDK и выкинул комнату.
    primary = _primary ?? primary;
    if (primary == null || !identical(primary(), client)) return;
    final loading = client.roomsLoading;
    if (client.rooms.isEmpty &&
        loading != null &&
        !identical(_readyRooms[client], loading)) {
      try {
        await loading.timeout(nativeDeadline);
      } on TimeoutException {
        return;
      }
      if (!identical(client.roomsLoading, loading)) return;
      _readyRooms[client] = loading;
      if (!identical(primary(), client)) return;
    }
    try {
      await UnseenOrderCache.reconcile(client).timeout(nativeDeadline);
    } on TimeoutException {
      return;
    }
    final count = visibleUnreadCount(client);
    if (count == null) return;
    await trySetPrimary(count, owner: client, primary: primary);
  }

  /// Персистит клиентское число в App Group (iOS/macOS) — там его читает NSE
  /// при закрытом приложении. Пишем ТОЛЬКО целое число (атомарно), без набора
  /// roomId: инкремент/набор в NSE давал бы cross-process гонки и двойной счёт.
  /// Best-effort: провал канала не критичен (в фон-изоляте плагин может быть
  /// не зарегистрирован). Пишется при КАЖДОМ trySet, поэтому в App Group всегда
  /// последнее клиентское число, а не серверное.
  static Future<void> _persistCount(int count, String? ownerName) async {
    if (kIsWeb || !(Platform.isIOS || Platform.isMacOS)) return;
    try {
      await _apnsChannel.invokeMethod('saveBadgeCount', {
        'count': count,
        if (ownerName != null) 'clientName': ownerName,
      });
    } on PlatformException {
      // best-effort
    } on MissingPluginException {
      // фоновый изолят без зарегистрированного плагина — не критично
    }
  }

  /// Человекочитаемая расшифровка ответа `getNotificationSettings` (iOS/macOS).
  ///
  /// Вынесена ЧИСТОЙ функцией (без обращения к каналу), чтобы проверяться на
  /// host-VM: сам нативный вызов в тесте недоступен, а именно расшифровка —
  /// то, что читает человек в логе пользователя.
  ///
  /// Коды — сырые `rawValue` UserNotifications:
  /// `UNAuthorizationStatus` (0 notDetermined, 1 denied, 2 authorized,
  /// 3 provisional, 4 ephemeral) и `UNNotificationSetting`
  /// (0 notSupported, 1 disabled, 2 enabled).
  @visibleForTesting
  static String describeNotificationSettings(Map<Object?, Object?> raw) {
    const auth = {
      0: 'notDetermined',
      1: 'denied',
      2: 'authorized',
      3: 'provisional',
      4: 'ephemeral',
    };
    const setting = {0: 'notSupported', 1: 'disabled', 2: 'enabled'};
    String s(String key, Map<int, String> names) {
      final v = raw[key];
      return v is int ? (names[v] ?? 'unknown($v)') : 'absent';
    }

    return 'auth=${s('authorization', auth)} '
        'alert=${s('alert', setting)} '
        'badge=${s('badge', setting)} '
        'sound=${s('sound', setting)}';
  }

  /// Спросить ОС о фактических настройках уведомлений и залогировать ОДНОЙ
  /// строкой. Зовётся на resume, а не на каждый sync — это диагностика, а не
  /// телеметрия.
  ///
  /// Зачем: по логу пользователя было НЕВОЗМОЖНО отличить «система подавила
  /// бейдж» от «мы его не записали». `monitoring.dart` не логирует ничего,
  /// `AppBadge` — одну строку и только на `PlatformException`, которого на
  /// macOS не бывает (см. [describeNotificationSettings]). Инцидент 2026-09-09:
  /// в 6263-строчном логе за 19 дней не нашлось ни одной строки про бейдж.
  ///
  /// Возвращает сырой `UNAuthorizationStatus` (или `null`, если узнать не
  /// удалось) — по нему resume шлёт сигнал `os_denied` в мониторинг.
  static Future<int?> logNotificationSettings() async {
    if (kIsWeb || !(Platform.isIOS || Platform.isMacOS)) return null;
    try {
      final raw = await _apnsChannel.invokeMethod('getNotificationSettings');
      if (raw is Map) {
        Logs().i('[Badge] os settings: ${describeNotificationSettings(raw)}');
        final authorization = raw['authorization'];
        final status = authorization is int ? authorization : null;
        await NotificationAuthTracker.observe(status);
        return status;
      }
    } on PlatformException catch (e) {
      Logs().i('[Badge] os settings недоступны: ${e.code}');
    } on MissingPluginException {
      // Сборка старее той, где метод появился (iOS `ApnsPushPlugin` / macOS
      // `MacApnsPushPlugin`) — диагностики просто не будет, ронять нельзя.
    }
    return null;
  }

  /// `UNAuthorizationStatus.denied`.
  static const int authorizationDenied = 1;

  /// Форс перерисовки Dock на macOS (K-A): `NSApp.dockTile.display()`. Без него
  /// иконка при активном окне может не показать свежий `badgeLabel`. Best-effort.
  static Future<void> _refreshDockBadge() async {
    try {
      await _apnsChannel.invokeMethod('refreshDockBadge');
    } on PlatformException {
      // best-effort
    } on MissingPluginException {
      // фон-изолят без плагина
    }
  }

  /// Выставить бейдж в [count] (0 — убрать). Ошибки платформы гасятся:
  /// на iOS removeBadge — тот же setBadgeCount(0) и тоже кидает
  /// PERMISSION_DENIED, поэтому через try/catch идут оба вызова.
  @visibleForTesting
  static Future<void> trySet(int count) => _write(count, () => true, null);

  static Future<void> trySetPrimary(
    int count, {
    required Client owner,
    required Client? Function() primary,
  }) => _setPrimary(count, owner, primary, repairLate: true);

  static Future<void> _setPrimary(
    int count,
    Client owner,
    Client? Function() primary, {
    required bool repairLate,
  }) {
    final epoch = _bindingEpoch;
    final user = owner.userID, device = owner.deviceID;
    bool current() =>
        epoch == _bindingEpoch &&
        identical((_primary ?? primary)(), owner) &&
        owner.isLogged() &&
        user == owner.userID &&
        device == owner.deviceID &&
        visibleUnreadCount(owner) == count;
    void reconcileLateWriter() {
      if (!repairLate ||
          current() ||
          (_primary == null && epoch != _bindingEpoch)) {
        return;
      }
      final resolve = _primary ?? primary;
      final latest = resolve();
      if (latest == null || !latest.isLogged()) return;
      final desired = visibleUnreadCount(latest);
      if (desired == null) return;
      // Нативный API мог применить старую команду уже после таймаута. Только
      // сам writer восстанавливает текущий primary; один восстановительный вызов.
      unawaited(
        _setPrimary(
          desired,
          latest,
          resolve,
          repairLate: false,
        ).catchError((_) {}),
      );
    }

    Future<void> write() async {
      if (!current()) return;
      final session = PushContractSession.observing(owner);
      final revision = session?.revision;
      final snapshot = session?.aggregate(null);
      final seq = _writeSeq;
      await _write(
        count,
        current,
        owner.clientName,
        lateResult: reconcileLateWriter,
      );
      if (snapshot != null &&
          current() &&
          _writeSeq > seq &&
          revision == session?.revision) {
        session?.recordBadge(count, snapshot);
      }
    }

    final previous = _writes;
    final next = previous == null ? write() : previous.then((_) => write());
    final lane = next.catchError((_) {});
    _writes = lane;
    lane.whenComplete(() {
      if (identical(_writes, lane)) _writes = null;
    });
    return next;
  }

  static Future<void> _write(
    int count,
    bool Function() current,
    String? ownerName, {
    void Function()? lateResult,
  }) async {
    // В браузере нет нативного badge/App Group. Не обращаемся к dart:io и
    // не выдаём пропуск за применённую запись (_writeSeq остаётся прежним).
    if (kIsWeb) return;

    Future<bool> bounded(Future<void> native) async {
      // Следующая команда не зависит от прихода callback предыдущей. Поздний
      // результат не меняет writeSeq/permission latch завершённой операции.
      try {
        await native
            .then((_) {
              if (!current()) lateResult?.call();
            })
            .timeout(nativeDeadline);
        return current();
      } on TimeoutException {
        return false;
      }
    }

    // Персист в App Group идёт ВСЕГДА (до permission-латча и независимо от
    // него): запись числа в разделяемый контейнер не требует badge-permission,
    // а NSE обязан видеть свежее клиентское число, даже если сам бейдж на
    // иконке пользователь запретил.
    await bounded(_persistCount(count, ownerName));
    if (!current()) return;
    // Снятие бейджа (count == 0) пробуем ВСЕГДА, даже под _denied-латчем:
    // иначе один PERMISSION_DENIED от setBadge навсегда заклинивал бы залипшую
    // «1» до resume — removeBadge не давал бы её снять. Установка (>0) под
    // латчем по-прежнему глушится, чтобы не спамить платформенными ошибками.
    if (_denied && count != 0) return;
    if (Platform.isIOS && !_permissionFlowDone) return;
    try {
      final applied = await bounded(
        count == 0
            ? FlutterNewBadger.removeBadge()
            : FlutterNewBadger.setBadge(count),
      );
      if (!applied) return;
      // Успешный вызов — латч самозаживает (не ждём resetDenied на resume).
      _denied = false;
      _writeSeq++;
      // В журнал — только СМЕНА числа: запись идёт на каждый sync, и без этого
      // бейдж вытеснил бы из кольца журнала всё остальное. Это факт записи, а
      // не отрисовки (read-back на macOS тавтологичен).
      if (count != _lastJournaledCount) {
        _lastJournaledCount = count;
        PushJournal.instance.record(PushStage.badge, value: count);
      }
      // K-A (macOS): dockTile.badgeLabel выставлен, но Dock может не
      // перерисоваться при frontmost-окне — форсим перерисовку нативно.
      if (Platform.isMacOS) {
        await _refreshDockBadge().timeout(nativeDeadline, onTimeout: () {});
      }
    } on PlatformException catch (e) {
      if (!current()) return;
      _denied = true;
      if (!_deniedLogged) {
        _deniedLogged = true;
        Logs().i('[Badge] disabled until resume: ${e.code}');
      }
    } on MissingPluginException {
      if (current()) _denied = true;
    }
  }
}
