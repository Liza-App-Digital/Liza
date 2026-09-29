// ignore_for_file: depend_on_referenced_packages

// Страж: Liza АКТИВНА на macOS, сообщение в НЕоткрытый чат → ровно один баннер
// при любом порядке «APNs / sync» (разбор жалобы Саши 2026-09-28,
// `howItWoks/pushes/pushes.md` §22).
//
// Было: пуш обогнал sync → Dart ставил «APNs already handled» и закрывал
// локальный путь, а активная ветка `willPresent` отдавала `[.sound, .list,
// .badge]` без `.banner` — баннера не было ни одного, только звук.
// Стало: гейт отвечает `banner` ТОЛЬКО при `unknownEvent`; при `show` (локальный
// путь событие видел и сознательно промолчал) — прежнее `silent`.
//
// ledger:RL-macos-push-active-one-banner

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/apns_push_service.dart';
import 'package:liza/utils/background_push.dart';

import 'per_user_fake_api.dart';
import 'test_client.dart';

const _userA = '@aleksandr:nadezhda.liza.ru';
const _room = '!dm:nadezhda.liza.ru';

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

Future<void> _syncEvent(
  Client c,
  String eventId, {
  required int notificationCount,
}) =>
    c.handleSync(
      SyncUpdate(
        nextBatch: 'b-$eventId',
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
                  eventId: '\$create',
                  senderId: c.userID!,
                  originServerTs: DateTime.now(),
                  content: {'creator': c.userID},
                  stateKey: '',
                ),
              ],
              timeline: TimelineUpdate(
                events: [
                  MatrixEvent(
                    type: EventTypes.Message,
                    eventId: eventId,
                    senderId: '@nadya:nadezhda.liza.ru',
                    originServerTs: DateTime.now(),
                    content: {'msgtype': 'm.text', 'body': 'привет'},
                  ),
                ],
              ),
            ),
          },
        ),
      ),
    );

Map<String, dynamic> _push(String eventId) => {
      'room_id': _room,
      'event_id': eventId,
      'sender': '@nadya:nadezhda.liza.ru',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Client a;
  late BackgroundPush push;

  setUp(() async {
    a = await _client('Liza-1790580000000', _userA);
    push = BackgroundPush.forTest([a]);
  });

  tearDown(() async => a.dispose());

  // AC:RL-macos-push-active-one-banner/1
  test('пуш обогнал sync, локального показа не было → натив рисует баннер '
      'и закрывает локальный путь', () async {
    await _syncEvent(a, '\$old', notificationCount: 0);
    const eventId = '\$ahead-of-sync';

    expect(await push.nativeBannerGate(_push(eventId)), NativeBannerGate.banner);
    expect(push.isNativelyReceived(eventId), isTrue,
        reason: 'иначе sync следом даст второй баннер');
  });

  // AC:RL-macos-push-active-one-banner/2
  test('локальный баннер уже показан → натив подавляет', () async {
    const eventId = '\$shown-locally';
    push.markLocallyShown(eventId);

    expect(
      await push.nativeBannerGate(_push(eventId)),
      NativeBannerGate.suppress,
    );
  });

  // AC:RL-macos-push-active-one-banner/3
  // Red-proof: `.banner` на ЛЮБОЙ не-suppress дал бы шквал старых баннеров после
  // сна — локальный путь видел событие и промолчал (возраст/скрытая комната).
  test('событие известно, комната непрочитана → silent, не banner', () async {
    const eventId = '\$known-unread';
    await _syncEvent(a, eventId, notificationCount: 2);

    expect(
      await push.nativeBannerGate(_push(eventId)),
      NativeBannerGate.silent,
    );
    expect(push.isNativelyReceived(eventId), isFalse);
  });

  // AC:RL-macos-push-active-one-banner/4
  test('событие известно и прочитано → suppress', () async {
    const eventId = '\$known-read';
    await _syncEvent(a, eventId, notificationCount: 0);

    expect(
      await push.nativeBannerGate(_push(eventId)),
      NativeBannerGate.suppress,
    );
  });

  // AC:RL-macos-push-active-one-banner/5
  test('counts-only пуш (без event_id) → silent', () async {
    expect(
      await push.nativeBannerGate({'room_id': _room}),
      NativeBannerGate.silent,
    );
  });

  // AC:RL-macos-push-active-one-banner/6
  // Окно гонки: sync успел показать локальный баннер между приходом пуша и
  // ответом гейта — второй, нативный, не нужен.
  test('unknownEvent, но локальный показ уже случился → suppress', () {
    const eventId = '\$race';
    push.markLocallyShown(eventId);

    expect(
      push.nativeBannerGateFor(ApnsBannerDecision.unknownEvent, eventId),
      NativeBannerGate.suppress,
    );
  });

  // AC:RL-macos-push-active-one-banner/7
  test('Swift: .banner только для banner в активной ветке, открытый чат — []',
      () {
    final delegate =
        File('macos/Runner/AppDelegate.swift').readAsStringSync();
    final plugin =
        File('macos/Runner/MacApnsPushPlugin.swift').readAsStringSync();

    expect(
      plugin,
      contains('case ${NativeBannerGate.values.map((g) => g.name).join(', ')}'),
      reason: 'имена решений уходят в Swift строкой — должны совпадать',
    );
    expect(plugin, contains('?? .silent'),
        reason: 'нераспознанный ответ канала — прежнее поведение, не баннер');
    expect(delegate, contains('pushAheadOfSync: gate == .banner'));
    expect(
      delegate,
      contains(
        'pushAheadOfSync ? [.banner, .sound, .list, .badge] : [.sound, .list, .badge]',
      ),
    );
    final activeRoom = delegate.indexOf('MacApnsPushPlugin.isActiveRoom(userInfo)');
    final bannerBranch = delegate.indexOf('pushAheadOfSync ? [.banner');
    expect(activeRoom, isNonNegative);
    expect(activeRoom, lessThan(bannerBranch),
        reason: 'открытый чат обязан глушиться раньше баннерной ветки');
  });
}
