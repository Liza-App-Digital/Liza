import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

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

  /// Request notification permission from the user.
  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } catch (e) {
      Logs().w('[APNs] requestPermission failed', e);
      return false;
    }
  }

  /// Get the native APNs device token as a hex string.
  Future<String?> getToken() async {
    try {
      final token = await _channel.invokeMethod<String>('getToken');
      Logs().v('[APNs] Got native APNs token: ${token?.substring(0, 16)}...');
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
  Future<void> saveCredentials({
    required String homeserverUrl,
    required String accessToken,
  }) async {
    try {
      await _channel.invokeMethod('saveCredentials', {
        'homeserverUrl': homeserverUrl,
        'accessToken': accessToken,
      });
    } catch (e) {
      Logs().w('[APNs] saveCredentials failed', e);
    }
  }

  /// Снять УЖЕ ПОКАЗАННЫЕ системой уведомления комнаты, включая нарисованные
  /// NSE/AppDelegate (их идентификатор — UUID от APNs, поэтому
  /// `flutterLocalNotificationsPlugin.cancel(id)` их не видит). Натив ищет по
  /// `threadIdentifier == roomId` — его проставляет NSE на каждом баннере.
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
