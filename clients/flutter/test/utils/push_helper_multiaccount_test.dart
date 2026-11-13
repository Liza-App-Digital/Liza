// ignore_for_file: depend_on_referenced_packages

// Страж clearing-ветки pushHelper при мультиаккаунте: clearing одного аккаунта
// НЕ гасит уведомления другого (нет cancelAll при ≥2 клиентах; чужой payload не
// трогаем), при этом одноклиентный путь (`RL-macos-push-background-banner` AC-4:
// cancelAll при unread=0) и гашение скрытой комнаты своего клиента
// (`RL-unread-rooms-badge-visible-only` AC-9) сохранены. РЕАЛЬНЫЙ pushHelper.
//
// ledger:RL-push-multiaccount-routing
// ledger:RL-macos-push-background-banner
// ledger:RL-unread-rooms-badge-visible-only

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/android_room_notification.dart';
import 'package:liza/utils/push_client_resolver.dart';
import 'package:liza/utils/push_helper.dart';

import 'per_user_fake_api.dart';
import 'test_client.dart';

class _RecordingLocalNotifications extends FlutterLocalNotificationsPlatform
    with MockPlatformInterfaceMixin {
  final List<String> calls = <String>[];
  final List<int> cancelledIds = <int>[];
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

const _n2 = '@nadezhda.rozental:nadezhda.liza.ru';
const _n3 = '@rozental.nadezhda:nadezhda.liza.ru';

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

Future<void> _joinUnread(
  Client c,
  String roomId,
  Map<String, dynamic> createContent,
) =>
    c.handleSync(
      SyncUpdate(
        nextBatch: 'b-${c.clientName}-$roomId',
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
                  senderId: c.userID!,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingLocalNotifications recorder;
  late FlutterLocalNotificationsPlugin plugin;
  late Client b, c;
  late L10n l10n;

  setUp(() async {
    recorder = _RecordingLocalNotifications();
    FlutterLocalNotificationsPlatform.instance = recorder;
    plugin = FlutterLocalNotificationsPlugin();
    b = await _client('Liza-1786629781847', _n2);
    c = await _client('Liza-1787253958881', _n3);
    l10n = await lookupL10n(const Locale('en'));
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await b.dispose();
    await c.dispose();
  });

  // AC:RL-push-multiaccount-routing/4
  test('2 клиента, clearing (unread=0) клиенту B: cancelAll НЕ вызван, '
      'уведомление C с чужим payload сохранено, скрытая комната B погашена',
      () async {
    const hiddenB = '!hiddenB:nadezhda.liza.ru';
    const visB = '!visB:nadezhda.liza.ru';
    const roomC = '!roomC:nadezhda.liza.ru';
    await _joinUnread(b, hiddenB, {'com.liza.chat.type': 'stories'});
    await _joinUnread(b, visB, const {});
    await _joinUnread(c, roomC, const {});

    final idHiddenB = pushNotificationId(b.clientName, hiddenB);
    final idVisB = pushNotificationId(b.clientName, visB);
    final idC = pushNotificationId(c.clientName, roomC);
    recorder.active = [
      ActiveNotification(
        id: idHiddenB,
        payload: LizaPushPayload(b.clientName, hiddenB, r'$e').toString(),
      ),
      ActiveNotification(
        id: idVisB,
        payload: LizaPushPayload(b.clientName, visB, r'$e').toString(),
      ),
      ActiveNotification(
        id: idC,
        payload: LizaPushPayload(c.clientName, roomC, r'$e').toString(),
      ),
    ];

    await pushHelper(
      PushNotification(
        devices: const [],
        counts: const PushNotificationCounts(unread: 0),
      ),
      clients: [b, c],
      clientName: b.clientName,
      l10n: l10n,
      flutterLocalNotificationsPlugin: plugin,
    );

    expect(recorder.calls, isNot(contains('cancelAll')),
        reason: 'при ≥2 аккаунтах cancelAll снёс бы уведомления соседа');
    expect(recorder.cancelledIds, contains(idHiddenB),
        reason: 'скрытая комната своего клиента гасится (AC-9 симметрия)');
    expect(recorder.cancelledIds, isNot(contains(idVisB)),
        reason: 'видимая непрочитанная своя — сохраняется');
    expect(recorder.cancelledIds, isNot(contains(idC)),
        reason: 'уведомление другого аккаунта (payload C) не трогаем');
  });

  // AC:RL-push-multiaccount-routing/4
  test('2 клиента: уведомление без payload и без совпавшей комнаты — '
      'неизвестный владелец, не гасим; legacy-id своей скрытой комнаты гасим',
      () async {
    const hiddenB = '!hiddenB:nadezhda.liza.ru';
    await _joinUnread(b, hiddenB, {'com.liza.chat.type': 'stories'});
    final legacyHidden = hiddenB.hashCode; // id прежней сборки, без скоупа
    const unknown = 424242;
    recorder.active = [
      ActiveNotification(id: legacyHidden),
      ActiveNotification(id: unknown),
    ];
    await pushHelper(
      PushNotification(
        devices: const [],
        counts: const PushNotificationCounts(unread: 1),
      ),
      clients: [b, c],
      clientName: b.clientName,
      l10n: l10n,
      flutterLocalNotificationsPlugin: plugin,
    );
    expect(recorder.cancelledIds, contains(legacyHidden));
    expect(recorder.cancelledIds, isNot(contains(unknown)));
  });

  // AC:RL-macos-push-background-banner/4
  // AC:RL-push-read-banner-sweep/15
  test('clearing: уведомление с id по событию и тегом комнаты (Р5) — комната '
      'берётся из тега/payload, непрочитанная видимая сохраняется, скрытая '
      'гасится', () async {
    const hiddenB = '!hiddenB:nadezhda.liza.ru';
    const visB = '!visB:nadezhda.liza.ru';
    await _joinUnread(b, hiddenB, {'com.liza.chat.type': 'stories'});
    await _joinUnread(b, visB, const {});
    final idVis = pushEventNotificationId(b.clientName, r'$v1');
    final idHidden = pushEventNotificationId(b.clientName, r'$h1');
    recorder.active = [
      ActiveNotification(
        id: idVis,
        tag: visB,
        payload: LizaPushPayload(b.clientName, visB, r'$v1').toString(),
      ),
      ActiveNotification(id: idHidden, tag: hiddenB),
    ];
    await pushHelper(
      PushNotification(
        devices: const [],
        counts: const PushNotificationCounts(unread: 1),
      ),
      clients: [b],
      clientName: b.clientName,
      l10n: l10n,
      flutterLocalNotificationsPlugin: plugin,
    );
    expect(recorder.cancelledIds, isNot(contains(idVis)),
        reason: 'непрочитанная видимая комната — баннер остаётся');
    expect(recorder.cancelledIds, contains(idHidden));
  });

  test('1 клиент, unread=0 → cancelAll как раньше (одноклиентный путь цел)',
      () async {
    await pushHelper(
      PushNotification(
        devices: const [],
        counts: const PushNotificationCounts(unread: 0),
      ),
      clients: [b],
      clientName: b.clientName,
      l10n: l10n,
      flutterLocalNotificationsPlugin: plugin,
    );
    expect(recorder.calls, contains('cancelAll'));
  });

  // AC:RL-push-multiaccount-routing/1
  test('clearing адресован по client_name: неизвестное имя → fallback первый',
      () async {
    const roomC = '!roomC:nadezhda.liza.ru';
    await _joinUnread(c, roomC, {'com.liza.chat.type': 'stories'});
    final idC = pushNotificationId(c.clientName, roomC);
    recorder.active = [
      ActiveNotification(
        id: idC,
        payload: LizaPushPayload(c.clientName, roomC, r'$e').toString(),
      ),
    ];
    await pushHelper(
      PushNotification(
        devices: const [],
        counts: const PushNotificationCounts(unread: 1),
      ),
      clients: [b, c],
      clientName: c.clientName,
      l10n: l10n,
      flutterLocalNotificationsPlugin: plugin,
    );
    expect(recorder.cancelledIds, contains(idC),
        reason: 'адресат C: его скрытая комната гасится');
  });

  // AC:RL-push-multiaccount-routing/4 (grep-страж: isolate не берёт .first)
  test('фоновый путь не берёт clients.first вслепую', () {
    for (final path in [
      'lib/utils/push_helper.dart',
      'lib/utils/notification_background_handler.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(
        RegExp(r'getClients\([^;]*\)\)\.first', dotAll: true).hasMatch(src),
        isFalse,
        reason: '$path: адресат фонового пуша/тапа — через clientForPush',
      );
      expect(src.contains('clientForPush('), isTrue, reason: path);
    }
  });
}
