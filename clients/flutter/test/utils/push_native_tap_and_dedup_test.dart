// ignore_for_file: depend_on_referenced_packages

// Стражи заявок поддержки №18/№19/№20 (Саша, 2026-09-16) — тап по нативному
// баннеру на macOS/iOS и симметрия дедупа «один баннер на событие».
//
// 1. Тап, пришедший в канал ДО `setListeners` (cold-start: Flutter дренирует
//    буфер канала в конструкторе `ApnsPushService`, а коллбэк навешивается после
//    `flutterLocalNotificationsPlugin.initialize()`), обязан дойти до коллбэка —
//    иначе «окно открылось, чат — нет».
// 2. Тёплый нативный тап идёт через общий `navigatePushTap` (сторис → вьюер).
// 3. APNs обогнал /sync → локальный баннер не дублирует нативный.
// 4. Снятие баннеров прочитанных комнат на resume ждёт первый /sync: квитанция
//    с другого устройства приезжает только им.
//
// ledger:RL-macos-push-tap-opens-room
// ledger:RL-macos-push-banner-read-suppress
// ledger:RL-push-tap-stories-opens-viewer

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/apns_push_service.dart';
import 'package:liza/utils/background_push.dart';

import 'per_user_fake_api.dart';
import 'test_client.dart';

const _channel = MethodChannel('com.prodamus.laba.liza/apns');
const _userA = '@nadezhda.rozental:nadezhda.liza.ru';
const _room = '!room:nadezhda.liza.ru';

/// `cancelDeliveredForReadRooms` на не-Apple платформе сразу выходит — на
/// Linux-раннере CI эти проверки не имеют смысла.
final _appleOnly =
    (Platform.isIOS || Platform.isMacOS) ? false : 'только на iOS/macOS-хосте';

/// Вызов натив → Dart по реальному каналу (как `channel.invokeMethod` из Swift).
Future<void> _nativeCall(String method, Map<String, dynamic> args) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  return messenger.handlePlatformMessage(
    _channel.name,
    _channel.codec.encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
}

Future<Client> _client(String name, String userId) {
  final host = userId.split(':').last;
  return prepareTestClient(
    loggedIn: true,
    clientName: name,
    userId: userId,
    homeserver: Uri.parse('https://$host'),
    httpClient: PerUserFakeMatrixApi(userId: userId, homeserverHost: host),
  );
}

Future<void> _syncRoom(Client c, {required int notificationCount}) =>
    c.handleSync(
      SyncUpdate(
        nextBatch: 'b-$notificationCount-${DateTime.now().microsecond}',
        rooms: RoomsUpdate(
          join: {
            _room: JoinedRoomUpdate(
              unreadNotifications: UnreadNotificationCounts(
                notificationCount: notificationCount,
                highlightCount: 0,
              ),
              state: [
                MatrixEvent(
                  type: EventTypes.RoomCreate,
                  eventId: '\$create-$_room',
                  senderId: c.userID!,
                  originServerTs: DateTime.now(),
                  content: {'creator': c.userID},
                  stateKey: '',
                ),
              ],
            ),
          },
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApnsPushService: тап до setListeners', () {
    // AC:RL-macos-push-tap-opens-room/2
    // Red-proof: без буфера `_pendingTap` коллбэк остаётся пустым — тап съеден.
    test('тап, пришедший ДО setListeners, доставляется сразу после', () async {
      final service = ApnsPushService();
      await _nativeCall('onNotificationTap', {
        'room_id': _room,
        'event_id': '\$ev',
        'client_name': 'Liza-1',
      });

      final taps = <(String, String, String?)>[];
      service.setListeners(
        onMessage: (_) {},
        onNotificationTap: (r, e, c) => taps.add((r, e, c)),
      );

      expect(taps, [(_room, '\$ev', 'Liza-1')]);

      // Буфер одноразовый: повторный setListeners тап не дублирует.
      service.setListeners(
        onMessage: (_) {},
        onNotificationTap: (r, e, c) => taps.add((r, e, c)),
      );
      expect(taps.length, 1);
    });

    // AC:RL-macos-push-tap-opens-room/3
    test('пустой room_id — коллбэка нет; пустой client_name → null', () async {
      final service = ApnsPushService();
      final taps = <(String, String, String?)>[];
      service.setListeners(
        onMessage: (_) {},
        onNotificationTap: (r, e, c) => taps.add((r, e, c)),
      );

      await _nativeCall('onNotificationTap', {'room_id': '', 'event_id': 'x'});
      expect(taps, isEmpty);

      await _nativeCall('onNotificationTap', {
        'room_id': _room,
        'event_id': '',
        'client_name': '',
      });
      expect(taps, [(_room, '', null)]);
    });
  });

  group('нативный слой macOS (структурные инварианты)', () {
    final root = Directory.current.path;
    final appDelegate =
        File('$root/macos/Runner/AppDelegate.swift').readAsStringSync();
    final plugin =
        File('$root/macos/Runner/MacApnsPushPlugin.swift').readAsStringSync();
    final backgroundPush =
        File('$root/lib/utils/background_push.dart').readAsStringSync();

    // AC:RL-macos-push-tap-opens-room/5
    // Класс дефекта 3758: AppDelegate — делегат центра уведомлений, но без
    // `didReceive` тап уходил в никуда (плагинный обработчик на macOS не зовётся).
    test('AppDelegate реализует didReceive и остаётся делегатом', () {
      expect(appDelegate, contains('UNUserNotificationCenter.current().delegate = self'));
      expect(appDelegate, contains('didReceive response: UNNotificationResponse'));
      expect(appDelegate, contains('MacApnsPushPlugin.didReceiveNotificationTap('));
    });

    // AC:RL-macos-push-tap-opens-room/6
    test('плагин держит pendingNotificationTap до регистрации канала', () {
      expect(plugin, contains('pendingNotificationTap = payload'));
      expect(
        plugin,
        isNot(contains("macOS doesn't have cold-start notification taps")),
      );
      // Dart опрашивает cold-start тап и на macOS, не только на iOS.
      expect(
        backgroundPush,
        contains('(Platform.isIOS || Platform.isMacOS) && !_wentToRoomOnStartup'),
      );
    });

    // AC:RL-push-tap-stories-opens-viewer/10
    // Тёплый нативный тап (iOS NSE / macOS) — тот же navigatePushTap, что у
    // локальных уведомлений; свой `router.go('/rooms/$roomId')` открывал бы
    // скрытый технический чат сторис.
    test('nativeNotificationTap делегирует navigatePushTap', () {
      final start = backgroundPush.indexOf('Future<void> nativeNotificationTap(');
      expect(start, greaterThan(0));
      final body = backgroundPush.substring(
        start,
        backgroundPush.indexOf('\n  }\n', start),
      );
      expect(body, contains('navigatePushTap('));
      expect(body, isNot(contains('router.go(')));
      // Единственная точка навигации по нативному тапу — эта функция.
      expect('router.go('.allMatches(backgroundPush), isEmpty);
    });
  });

  group('BackgroundPush: дедуп и resume', () {
    late Client a;
    late BackgroundPush push;
    final cancelled = <String>[];
    var delivered = <String>[];

    setUp(() async {
      a = await _client('Liza-1786629781847', _userA);
      push = BackgroundPush.forTest([a]);
      cancelled.clear();
      delivered = [_room];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        switch (call.method) {
          case 'deliveredRoomIds':
            return delivered;
          case 'cancelDeliveredForRoom':
            cancelled.add((call.arguments as Map)['roomId'] as String);
            return true;
        }
        return null;
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      await a.dispose();
    });

    // AC:RL-macos-push-banner-read-suppress/10
    // Обратная гонка: APNs пришёл раньше /sync — натив уже решил судьбу баннера,
    // локальное уведомление по тому же событию не показываем.
    test('APNs получен → событие помечено, локальный баннер лишний', () {
      expect(push.isNativelyReceived('\$fast-apns'), isFalse);
      push.markNativelyReceived('\$fast-apns');
      expect(push.isNativelyReceived('\$fast-apns'), isTrue);
      expect(push.isNativelyReceived('\$other'), isFalse);
      push.markNativelyReceived('');
      expect(push.isNativelyReceived(''), isFalse);
    });

    test('showLocalNotification сверяется с isNativelyReceived до показа', () {
      final ext = File(
        '${Directory.current.path}/lib/widgets/local_notifications_extension.dart',
      ).readAsStringSync();
      final check = ext.indexOf('isNativelyReceived(event.eventId)');
      final mark = ext.indexOf('markLocallyShown(event.eventId)');
      expect(check, greaterThan(0));
      expect(check, lessThan(mark));
    });

    // AC:RL-macos-push-banner-read-suppress/11
    // Red-proof: без ожидания sync проверка идёт по устаревшему состоянию
    // (комната ещё «непрочитана») и баннер остаётся до следующего resume.
    test('resume: квитанция приходит следующим sync → баннер снят', () async {
      await _syncRoom(a, notificationCount: 3);

      final done = push.cancelDeliveredForReadRooms();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cancelled, isEmpty, reason: 'до sync решения нет');

      await _syncRoom(a, notificationCount: 0);
      await done;

      expect(cancelled, [_room]);
    }, skip: _appleOnly);

    test('resume: комната по-прежнему непрочитана → баннер остаётся', () async {
      await _syncRoom(a, notificationCount: 3);

      final done = push.cancelDeliveredForReadRooms();
      await _syncRoom(a, notificationCount: 2);
      await done;

      expect(cancelled, isEmpty);
    });

    test('resume: sync молчит дольше таймаута → fail-open по текущему состоянию',
        () async {
      await _syncRoom(a, notificationCount: 0);

      await push
          .cancelDeliveredForReadRooms()
          .timeout(BackgroundPush.resumeSyncWait + const Duration(seconds: 2));

      expect(cancelled, [_room]);
    }, skip: _appleOnly);

    // ledger:RL-push-read-banner-sweep
    // AC:RL-push-read-banner-sweep/5
    // Р2 L2 на холодном старте: решение только ПОСЛЕ первого sync.
    test('запуск: первый sync показал «прочитано» → баннер снят', () async {
      final done = push.cancelDeliveredAfterFirstSync(
        delivered: () async => delivered,
        cancel: (r) async => cancelled.add(r),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cancelled, isEmpty, reason: 'до sync решения нет');
      await _syncRoom(a, notificationCount: 0);
      expect(await done, [_room]);
      expect(cancelled, [_room]);
    });

    // AC:RL-push-read-banner-sweep/6
    // Red-proof инварианта «по таймауту не чистим»: стор до sync не знает
    // свежего события и счёл бы комнату прочитанной.
    test('запуск: sync не пришёл за окно → ничего не снимаем', () async {
      await _syncRoom(a, notificationCount: 0);
      final dropped = await push.cancelDeliveredAfterFirstSync(
        wait: const Duration(milliseconds: 100),
        delivered: () async => delivered,
        cancel: (r) async => cancelled.add(r),
      );
      expect(dropped, isEmpty);
      expect(cancelled, isEmpty);
    });

    test('запуск: первый sync — комната непрочитана → баннер остаётся', () async {
      final done = push.cancelDeliveredAfterFirstSync(
        delivered: () async => delivered,
        cancel: (r) async => cancelled.add(r),
      );
      await _syncRoom(a, notificationCount: 2);
      expect(await done, isEmpty);
      expect(cancelled, isEmpty);
    });
  });
}
