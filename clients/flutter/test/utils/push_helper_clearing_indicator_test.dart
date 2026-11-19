// ignore_for_file: depend_on_referenced_packages

// Страж LABA-2354 (P2): «clearing indicator» в pushHelper НЕ должен трактовать
// нерезолвнутое событие С event_id как индикатор очистки и НЕ должен из-за этого
// гасить показанные уведомления. На macOS видимый баннер рисует нативный
// AppDelegate.willPresent, а эта Dart-ветка могла бы его снять.
//
// Тестирует РЕАЛЬНЫЙ pushHelper + РЕАЛЬНЫЙ Client.getEventByPushNotification
// (не реплику): getEventByPushNotification возвращает null, когда
// `eventId == null || roomId == null` (matrix-4.1.0 client.dart), что даёт
// детерминированный путь `event == null` без сетевых запросов. Вызовы плагина
// уведомлений перехватываются подставной FlutterLocalNotificationsPlatform.
//
// ledger:RL-macos-push-background-banner
// AC:RL-macos-push-background-banner/3
// AC:RL-macos-push-background-banner/4

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/push_helper.dart';

import 'test_client.dart';

/// Подставная реализация платформы: записывает имена вызванных методов, чтобы
/// проверить, обращается ли pushHelper к плагину уведомлений.
class _RecordingLocalNotifications extends FlutterLocalNotificationsPlatform
    with MockPlatformInterfaceMixin {
  final List<String> calls = <String>[];
  final List<int> cancelledIds = <int>[];

  /// Активные OS-нотификации, которые вернёт [getActiveNotifications].
  List<ActiveNotification> active = <ActiveNotification>[];

  @override
  Future<void> cancelAll() async => calls.add('cancelAll');

  @override
  Future<void> cancel(int id) async {
    calls.add('cancel');
    cancelledIds.add(id);
  }

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async {
    calls.add('getActiveNotifications');
    return active;
  }

  @override
  Future<void> show(int id, String? title, String? body, {String? payload}) async =>
      calls.add('show');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingLocalNotifications recorder;
  late FlutterLocalNotificationsPlugin plugin;
  late Client client;
  late L10n l10n;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    recorder = _RecordingLocalNotifications();
    FlutterLocalNotificationsPlatform.instance = recorder;
    plugin = FlutterLocalNotificationsPlugin();
    client = await prepareTestClient(loggedIn: true);
    l10n = await lookupL10n(const Locale('en'));
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await client.dispose();
  });

  test(
    'событие с event_id, которое не удалось резолвить, НЕ трактуется как '
    'clearing и не отменяет уведомления (AC-3)',
    () async {
      // eventId есть, roomId нет → getEventByPushNotification вернёт null, но
      // это реальное сообщение, а не индикатор очистки.
      await pushHelper(
        PushNotification(
          devices: const [],
          eventId: r'$unresolved:example.invalid',
          counts: const PushNotificationCounts(unread: 1),
        ),
        client: client,
        l10n: l10n,
        flutterLocalNotificationsPlugin: plugin,
      );

      // На коде ДО фикса такой пуш (event==null, unread=1) уходил в ветку
      // очистки и звал getActiveNotifications (+ oneShotSync) → потенциальные
      // отмены. После фикса — ранний return без единого обращения к плагину.
      // Отсюда red→green: пустой список вызовов невозможен на старом коде.
      expect(
        recorder.calls,
        isEmpty,
        reason: 'Нерезолвнутое событие с event_id не должно запускать очистку '
            'уведомлений (getActiveNotifications/cancel) — иначе гасим '
            'показанный нативный macOS-баннер.',
      );
    },
  );

  // AC:RL-macos-push-background-banner/4
  test(
    'counts-only пуш без event_id при unread=0 остаётся clearing-индикатором '
    '(cancelAll вызывается) — регресс-контроль настоящей очистки',
    () async {
      await pushHelper(
        PushNotification(
          devices: const [],
          counts: const PushNotificationCounts(unread: 0),
        ),
        client: client,
        l10n: l10n,
        flutterLocalNotificationsPlugin: plugin,
      );

      expect(
        recorder.calls,
        contains('cancelAll'),
        reason: 'Настоящий clearing-индикатор (нет event_id, unread=0) '
            'по-прежнему очищает уведомления.',
      );
    },
  );

  // Симметрия с бейджем непрочитанных: clearing-индикатор гасит зависшую
  // OS-нотификацию СКРЫТОЙ (stories/обсуждение канала) комнаты — её нельзя
  // открыть и «прочитать», иначе баннер завис бы неснимаемым (как фантомный
  // бейдж, [[RL-unread-rooms-badge-visible-only]]). Видимую непрочитанную —
  // сохраняет. Проверяет РЕАЛЬНЫЙ pushHelper на пути room-matching.
  // ledger:RL-unread-rooms-badge-visible-only
  // AC:RL-unread-rooms-badge-visible-only/9
  test(
    'clearing гасит нотификацию скрытой непрочитанной комнаты, видимую сохраняет',
    () async {
      Future<void> joinUnread(
        String roomId,
        Map<String, dynamic> createContent,
      ) =>
          client.handleSync(
            SyncUpdate(
              nextBatch: 'b-$roomId',
              rooms: RoomsUpdate(
                join: {
                  roomId: JoinedRoomUpdate(
                    unreadNotifications: UnreadNotificationCounts(
                      notificationCount: 2,
                      highlightCount: 0,
                    ),
                    state: [
                      MatrixEvent(
                        type: EventTypes.RoomCreate,
                        eventId: '\$c-$roomId',
                        senderId: '@alice:example.invalid',
                        originServerTs: DateTime.now(),
                        content: createContent,
                        stateKey: '',
                      ),
                    ],
                  ),
                },
              ),
            ),
          );

      await joinUnread('!hidden:example.invalid', {
        'com.liza.chat.type': 'stories',
      });
      await joinUnread('!vis:example.invalid', const {});

      final hiddenId = '!hidden:example.invalid'.hashCode;
      final visId = '!vis:example.invalid'.hashCode;
      recorder.active = [
        ActiveNotification(id: hiddenId),
        ActiveNotification(id: visId),
      ];

      // Настоящий clearing-индикатор: нет event_id, unread>0 → ветка
      // room-matching (getActiveNotifications + пофайловая отмена).
      await pushHelper(
        PushNotification(
          devices: const [],
          counts: const PushNotificationCounts(unread: 1),
        ),
        client: client,
        l10n: l10n,
        flutterLocalNotificationsPlugin: plugin,
      );

      expect(
        recorder.cancelledIds,
        contains(hiddenId),
        reason: 'скрытая непрочитанная комната: зависшую нотификацию гасим '
            '(её нельзя прочитать) — на старом коде (isUnreadOrInvited) НЕ '
            'гасилась → red→green.',
      );
      expect(
        recorder.cancelledIds,
        isNot(contains(visId)),
        reason: 'видимую непрочитанную комнату не трогаем — её нотификация '
            'легитимна.',
      );
    },
  );
}
