import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/notification_health.dart';
import 'package:liza/utils/screen_lock_state.dart';

/// Native APNs push service — drop-in replacement for FcmSharedIsolate on iOS.
/// Communicates with ApnsPushPlugin.swift via MethodChannel.
class ApnsPushService {
  static const _channel = MethodChannel('com.prodamus.laba.liza/apns');

  void Function(Map<dynamic, dynamic> message)? _onMessage;

  /// Тап по нативному уведомлению: room_id, event_id и `client_name` адресата
  /// (мультиаккаунт; Sygnal мержит `default_payload.client_name` в userInfo).
  void Function(String roomId, String eventId, String? clientName)?
  _onNotificationTap;

  /// Тап, пришедший ДО `setListeners`. Обработчик канала ставится в
  /// конструкторе — в этот момент Flutter отдаёт сообщения, накопленные до
  /// старта Dart (cold-start по клику на баннер), а коллбэк навешивается
  /// только после `flutterLocalNotificationsPlugin.initialize()`. Без буфера
  /// такой тап молча терялся: окно открывалось, чат — нет (заявка №18).
  ({String roomId, String eventId, String? clientName})? _pendingTap;

  /// Нативный слой спрашивает ПЕРЕД показом APNs-баннера, как его показать.
  /// Единственный источник ответа — живой клиент (прочитанность, дубль
  /// локального баннера); натив своей копии состояния не держит.
  Future<NativeBannerGate> Function(Map<String, dynamic> userInfo)?
  _nativeBannerGate;

  ApnsPushService() {
    _channel.setMethodCallHandler(_handleMethod);
    if (!kIsWeb && Platform.isMacOS) unawaited(_syncScreenLock());
  }

  /// Начальное состояние блокировки экрана (нативные уведомления приходят
  /// только на СМЕНУ). Best-effort: нет плагина — остаёмся в `false`.
  Future<void> _syncScreenLock() async {
    try {
      final locked = await _channel.invokeMethod<bool>('getScreenLocked');
      if (locked != null) ScreenLockState.update(locked);
    } on PlatformException {
      // best-effort
    } on MissingPluginException {
      // фон-изолят / платформа без плагина
    }
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'onMessage':
        final data = Map<dynamic, dynamic>.from(call.arguments as Map);
        _onMessage?.call(data);
        break;
      case 'onNotificationTap':
        final data = Map<String, dynamic>.from(call.arguments as Map);
        final roomId = data['room_id'] as String? ?? '';
        final eventId = data['event_id'] as String? ?? '';
        final clientName = data['client_name'] as String?;
        if (roomId.isNotEmpty) {
          final tap = (
            roomId: roomId,
            eventId: eventId,
            clientName: (clientName?.isEmpty ?? true) ? null : clientName,
          );
          final handler = _onNotificationTap;
          if (handler == null) {
            Logs().v('[APNs] Notification tap before listeners — buffered');
            _pendingTap = tap;
          } else {
            handler(tap.roomId, tap.eventId, tap.clientName);
          }
        }
        break;
      case 'onToken':
        // Token updates are handled via getToken()
        Logs().v('[APNs] Token updated via native callback');
        break;
      case 'onScreenLock':
        final locked = call.arguments == true;
        Logs().v('[APNs] Screen ${locked ? 'locked' : 'unlocked'}');
        ScreenLockState.update(locked);
        break;
      case 'onJournal':
        // Нативные стадии (macOS): сон/пробуждение, опции `willPresent`,
        // сбой `center.add`. Натив шлёт ПОСЛЕ completionHandler — ответ
        // системе не ждёт Dart (RL-macos-push-active-one-banner).
        PushJournal.instance.recordNative(call.arguments);
        break;
      case 'shouldSuppressBanner':
        // Ответ — имя [NativeBannerGate] (`MacApnsPushPlugin.swift` разбирает
        // строку). Fail-open: нет обработчика / ошибка → `silent`, т.е. прежнее
        // поведение без подавления. Потерянное уведомление хуже лишнего
        // (инвариант LABA-2354).
        final handler = _nativeBannerGate;
        if (handler == null) return NativeBannerGate.silent.name;
        try {
          final data = Map<String, dynamic>.from(call.arguments as Map);
          return (await handler(data)).name;
        } catch (e, s) {
          Logs().w('[APNs] shouldSuppressBanner failed', e, s);
          return NativeBannerGate.silent.name;
        }
    }
  }

  /// Снимок окружения уведомлений для тегов push-report (только macOS/iOS;
  /// чего натив не умеет — просто нет в ответе).
  Future<Map<String, String>> environmentTags({
    NotificationHealthSnapshot? snapshot,
  }) async {
    final tags = <String, String>{};
    final health = snapshot ?? await NotificationHealth.instance.refresh();
    tags.addAll(health.tags);
    tags.addAll(await NotificationAuthTracker.reportTags());
    try {
      final raw = await _channel
          .invokeMethod('getAppCopies')
          .timeout(const Duration(seconds: 3));
      if (raw is Map) tags.addAll(appCopiesTags(raw));
    } catch (_) {}
    return tags;
  }

  /// `UNAuthorizationStatus` / `UNNotificationSetting` / `UNAlertStyle` →
  /// стабильные имена для тегов когорты.
  @visibleForTesting
  static Map<String, String> notificationSettingsTags(
    Map<Object?, Object?> raw,
  ) {
    return NotificationHealth.settingsTags(raw);
  }

  @visibleForTesting
  static Map<String, String> appCopiesTags(Map<Object?, Object?> raw) {
    final out = <String, String>{};
    for (final (tag, key) in const [
      ('liza.app_copies', 'copies'),
      ('liza.legacy_copies', 'legacyCopies'),
      ('liza.running_copies', 'running'),
    ]) {
      final v = raw[key];
      if (v is int) out[tag] = '$v';
    }
    final location = raw['location'];
    if (const {
      'translocated',
      'applications',
      'volumes',
      'downloads',
      'user_applications',
      'dev_build',
      'other',
    }.contains(location)) {
      out['liza.install_location'] = location as String;
    }
    return out;
  }

  /// Запрос разрешения на уведомления. Ответ системы (статус до/после,
  /// ошибка, активность приложения, длительность) уходит в журнал и теги
  /// push-report — поведение вызывающих не меняется, они получают `granted`.
  Future<bool> requestPermission({
    AuthRequestSource source = AuthRequestSource.setupPusher,
  }) async {
    final started = DateTime.now();
    try {
      final raw = await _channel.invokeMethod<Object?>('requestPermission');
      final result = AuthRequestResult.parse(
        raw,
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
      );
      Logs().i(
        '[APNs] requestPermission source=${source.name} '
        'outcome=${result.outcome.name} before=${result.before} '
        'after=${result.after} err=${result.errorTag} active=${result.active} '
        'ms=${result.elapsedMs}',
      );
      unawaited(
        NotificationAuthTracker.noteRequest(
          result,
          source: source,
          state: WidgetsBinding.instance.lifecycleState,
        ),
      );
      return result.granted;
    } catch (e) {
      Logs().w('[APNs] requestPermission failed', e);
      return false;
    }
  }

  /// Текущий статус разрешения (`UNAuthorizationStatus`) — с записью смены в
  /// журнал. `null`, если узнать не удалось (нет плагина, таймаут).
  Future<int?> authorizationStatus({
    Duration timeout = const Duration(seconds: 3),
    bool? hasSession,
  }) async {
    final health = await NotificationHealth.instance.refresh(
      hasSession: hasSession,
    );
    final auth = NotificationHealth.authorization(health.tags);
    await NotificationAuthTracker.observe(auth, hasSession: hasSession);
    return auth;
  }

  Future<List<Map<String, Object>>> diagnosticJournal() =>
      NativePushDiagnostics.readJournal();

  /// Get the native APNs device token as a hex string.
  Future<String?> getToken() async {
    try {
      final token = await _channel.invokeMethod<String>('getToken');
      Logs().v('[APNs] Native token available: ${token != null}');
      return token;
    } catch (e) {
      Logs().w('[APNs] getToken failed', e);
      return null;
    }
  }

  /// Check if the app was launched by tapping a remote notification (cold start).
  /// Returns a map with room_id, event_id (and client_name of the addressee
  /// account, if the push carried it), or null if no pending tap.
  Future<Map<String, String>?> getInitialNotificationTap() async {
    try {
      final result = await _channel.invokeMapMethod<String, String>(
        'getInitialNotificationTap',
      );
      if (result != null && (result['room_id']?.isNotEmpty ?? false)) {
        Logs().v(
          '[APNs] Got initial notification tap for room: ${result['room_id']}',
        );
        return result;
      }
      return null;
    } catch (e) {
      Logs().w('[APNs] getInitialNotificationTap failed', e);
      return null;
    }
  }

  /// Save homeserver URL and access token to shared App Group container
  /// so the Notification Service Extension can download avatars.
  ///
  /// [clientName] → ключи `homeserverUrl.<clientName>`/`accessToken.<clientName>`:
  /// NSE снимает прочитанные баннеры токеном аккаунта-адресата пуша (Р2 L1),
  /// а не токеном «текущего» аккаунта. [legacy] — дополнительно писать ключи
  /// без суффикса (аватар в NSE и сборки NSE без поддержки суффиксов).
  Future<void> saveCredentials({
    required String homeserverUrl,
    required String accessToken,
    String? clientName,
    bool legacy = true,
  }) async {
    try {
      await _channel.invokeMethod('saveCredentials', {
        'homeserverUrl': homeserverUrl,
        'accessToken': accessToken,
        'clientName': ?clientName,
        'legacy': legacy ? 'true' : 'false',
      });
    } catch (e) {
      Logs().w('[APNs] saveCredentials failed', e);
    }
  }

  /// Выход из аккаунта [clientName]: натив удаляет его `accessToken.<cn>`
  /// (и легаси-ключи, если в них тот же токен или аккаунтов не осталось) и
  /// перезаписывает список аккаунтов [remaining] для холодной чистки NSE.
  Future<void> removeCredentials(
    String clientName, {
    required List<String> remaining,
  }) async {
    try {
      await _channel.invokeMethod('removeCredentials', {
        'clientName': clientName,
        'remaining': remaining,
      });
    } catch (e) {
      Logs().w('[APNs] removeCredentials failed', e);
    }
  }

  /// Снять УЖЕ ПОКАЗАННЫЕ системой уведомления комнаты, включая нарисованные
  /// NSE/AppDelegate (их идентификатор — UUID от APNs, поэтому
  /// `flutterLocalNotificationsPlugin.cancel(id)` их не видит). Натив ищет по
  /// `threadIdentifier == roomId` (его проставляет iOS-NSE) или по
  /// `userInfo["room_id"]` — на macOS NSE нет, там работает только второе.
  Future<void> cancelDeliveredForRoom(String roomId) async {
    try {
      await _channel.invokeMethod('cancelDeliveredForRoom', {'roomId': roomId});
    } catch (e) {
      Logs().w('[APNs] cancelDeliveredForRoom failed', e);
    }
  }

  /// Clearing-пуш обработан: натив отпускает `completionHandler` фонового
  /// пробуждения (iOS держит окно до этого ответа, не дольше 25 с).
  /// [id] — метка пуша от натива (`liza_clear_id`): отпускается окно именно
  /// этого пуша, а не всех ждущих.
  Future<void> clearingDone(String? id) async {
    if (id == null) return;
    try {
      await _channel.invokeMethod('clearingDone', {'id': id});
    } catch (e) {
      Logs().w('[APNs] clearingDone failed', e);
    }
  }

  /// Аккаунты этого устройства → App Group: по clearing-пушу при выгруженном
  /// приложении натив снимает баннер без client_name, только если аккаунт один.
  Future<void> saveClientNames(List<String> names) async {
    try {
      await _channel.invokeMethod('saveClientNames', {'names': names});
    } catch (e) {
      Logs().w('[APNs] saveClientNames failed', e);
    }
  }

  /// Снять опоздавший APNs-баннер конкретного события после того, как его
  /// показала система (macOS, приложение не активно — `willPresent` там не
  /// зовётся). Натив опрашивает доставленные уведомления до ~10 с и матчит по
  /// `userInfo["event_id"]`. Возвращает миллисекунды до снятия; `null` — не
  /// нашли (не показан / уже снят / канал недоступен).
  Future<int?> retractDelivered(String eventId) async {
    try {
      return await _channel.invokeMethod<int>('retractDelivered', {
        'eventId': eventId,
      });
    } catch (e) {
      Logs().w('[APNs] retractDelivered failed', e);
      return null;
    }
  }

  /// macOS, Р3: локальный баннер нативным запросом с идентификатором
  /// [identifier] = `pushBannerId` — тем же, что APNs-баннер получает из
  /// `apns-collapse-id`. Натив не показывает, если баннер события уже есть.
  /// Ответ: `shown` / `skipped` / `failed`; ошибка канала — `null`
  /// (вызывающий откатывается на плагин, баннер не теряем).
  Future<String?> showBanner({
    required String identifier,
    required String title,
    required String body,
    required String roomId,
    required String eventId,
    required String clientName,
    String? attachmentPath,
  }) async {
    try {
      return await _channel.invokeMethod<String>('showBanner', {
        'identifier': identifier,
        'title': title,
        'body': body,
        'roomId': roomId,
        'eventId': eventId,
        'clientName': clientName,
        'attachmentPath': attachmentPath,
      });
    } catch (e) {
      Logs().w('[APNs] showBanner failed', e);
      return null;
    }
  }

  /// macOS: показан ли системой баннер события (матч по `userInfo["event_id"]`).
  /// Ошибка/недоступный канал — `false`: лишний баннер безопаснее потерянного.
  Future<bool> isEventDelivered(String eventId) async {
    try {
      return await _channel.invokeMethod<bool>('isEventDelivered', {
            'eventId': eventId,
          }) ??
          false;
    } catch (e) {
      Logs().w('[APNs] isEventDelivered failed', e);
      return false;
    }
  }

  /// Комнаты уже показанных системой уведомлений (`threadIdentifier`). Нужен,
  /// чтобы на resume снять баннеры тех комнат, которые пользователь успел
  /// прочитать на другом устройстве.
  Future<List<String>> deliveredRoomIds() async {
    try {
      final rooms = await _channel.invokeListMethod<String>('deliveredRoomIds');
      return rooms ?? const [];
    } catch (e) {
      Logs().w('[APNs] deliveredRoomIds failed', e);
      return const [];
    }
  }

  /// Set listener for incoming push notifications.
  void setListeners({
    required void Function(Map<dynamic, dynamic> message) onMessage,
    void Function(String roomId, String eventId, String? clientName)?
    onNotificationTap,
    Future<NativeBannerGate> Function(Map<String, dynamic> userInfo)?
    nativeBannerGate,
  }) {
    _onMessage = onMessage;
    _onNotificationTap = onNotificationTap;
    _nativeBannerGate = nativeBannerGate;
    final pending = _pendingTap;
    if (pending != null && onNotificationTap != null) {
      _pendingTap = null;
      onNotificationTap(pending.roomId, pending.eventId, pending.clientName);
    }
  }
}

/// Ответ нативному `willPresent` активного приложения (канал `shouldSuppressBanner`).
/// Имена уходят в Swift строкой — менять синхронно с `MacApnsPushPlugin`.
enum NativeBannerGate {
  /// Не показывать: уже показан локально или прочитано.
  suppress,

  /// Показать оригинал с баннером: пуш обогнал sync, локальный путь закрыт.
  banner,

  /// Как раньше: звук и запись в Центре уведомлений, баннер — за локальным путём.
  silent,
}
