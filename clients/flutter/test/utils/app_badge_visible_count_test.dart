// ignore_for_file: depend_on_referenced_packages

// Страж RL-app-badge-native-visible-count: число, которым клиент кормит нативный
// фон-путь бейджа (App Group для NSE, `number` Android-нотификации), считается по
// ВИДИМЫМ непрочитанным комнатам (`countsTowardAppBadge`), а НЕ по сырому
// серверному `counts.unread`. Сервер считает topology-скрытые (stories) и
// server-stuck (федеративные) комнаты, которые клиент исключает → без этого
// инварианта бейдж накопительно завышается («5» при одном реальном непрочитанном).
//
// ledger:RL-app-badge-native-visible-count
//
// Покрывает Dart-часть (AC-1..7). Нативный слой (NSE/Dock/launcher badge) на
// Dart-VM не воспроизводится — он в manual/device-flow чек-листе (AC-8..10).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/app_badge.dart';

import 'test_client.dart';

const _apnsChannel = MethodChannel('com.prodamus.laba.liza/apns');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Client client;
  // Последнее число, ушедшее в App Group через saveBadgeCount (нативный писатель).
  int? persistedBadge;

  setUp(() async {
    persistedBadge = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_apnsChannel, (call) async {
      if (call.method == 'saveBadgeCount') {
        persistedBadge = (call.arguments as Map)['count'] as int;
      }
      return true;
    });
    AppBadge.resetDenied();
    client = await prepareTestClient(loggedIn: true);
    // Логин запускает фоновый sync-loop (FakeMatrixApi отвечает бесконечно) —
    // комнаты наполняем вручную через handleSync, фоновый sync не нужен.
    AppBadge.bindPrimary(client, () => client);
    client.backgroundSync = false;
    await client.abortSync();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_apnsChannel, null);
    AppBadge.unbindPrimary(client);
    await client.dispose(closeDatabase: true);
  });

  Future<void> joinUnreadRoom(
    String roomId, {
    Map<String, dynamic> createContent = const {},
    Map<String, dynamic>? topologyContent,
    int notificationCount = 2,
  }) =>
      client.handleSync(
        SyncUpdate(
          nextBatch: 'b-$roomId',
          rooms: RoomsUpdate(
            join: {
              roomId: JoinedRoomUpdate(
                unreadNotifications: UnreadNotificationCounts(
                  notificationCount: notificationCount,
                  highlightCount: 0,
                ),
                state: [
                  MatrixEvent(
                    type: EventTypes.RoomCreate,
                    eventId: '\$create-$roomId',
                    senderId: '@alice:example.invalid',
                    originServerTs: DateTime.now(),
                    content: createContent,
                    stateKey: '',
                  ),
                  if (topologyContent != null)
                    MatrixEvent(
                      type: 'com.liza.chat.topology',
                      eventId: '\$topology-$roomId',
                      senderId: '@alice:example.invalid',
                      originServerTs: DateTime.now(),
                      content: topologyContent,
                      stateKey: '',
                    ),
                ],
              ),
            },
          ),
        ),
      );

  Future<void> inviteRoom(
    String roomId, {
    Map<String, dynamic> createContent = const {},
  }) =>
      client.handleSync(
        SyncUpdate(
          nextBatch: 'b-inv-$roomId',
          rooms: RoomsUpdate(
            invite: {
              roomId: InvitedRoomUpdate(
                inviteState: [
                  StrippedStateEvent(
                    type: EventTypes.RoomCreate,
                    senderId: '@alice:example.invalid',
                    content: createContent,
                    stateKey: '',
                  ),
                ],
              ),
            },
          ),
        ),
      );

  // FakeMatrixApi при логине наполняет client.rooms дефолтными комнатами —
  // проверяем ДЕЛЬТУ поверх базовой линии, чтобы инвариант не зависел от
  // дефолтов эмулятора (как и в RL-unread-rooms-badge-visible-only).

  // AC-1: сервер «видел бы» +5 (1 обычная + 4 скрытых непрочитанных), клиент —
  // +1. Это дословный кейс жалобы «5 при одном чате»: 4 скрытых не идут в число.
  // Red-proof: возврат к counts.unread раздул бы дельту до +5 → падение.
  // AC:RL-app-badge-native-visible-count/1
  test('5 серверных vs 1 видимый непрочитанный → дельта числа = +1', () async {
    final base = AppBadge.visibleUnreadCount(client)!;
    await joinUnreadRoom('!normal:example.invalid');
    await joinUnreadRoom(
      '!s1:example.invalid',
      createContent: {'com.liza.chat.type': 'stories'},
    );
    await joinUnreadRoom(
      '!s2:example.invalid',
      createContent: {'com.liza.chat.type': 'stories'},
    );
    await joinUnreadRoom(
      '!d1:example.invalid',
      createContent: {'com.liza.chat.type': 'channel_discussion'},
      topologyContent: const {'hidden': true},
    );
    await joinUnreadRoom(
      '!d2:example.invalid',
      createContent: {'com.liza.chat.type': 'channel_discussion'},
      topologyContent: const {'hidden': true},
    );
    expect(AppBadge.visibleUnreadCount(client), base + 1);
  });

  // AC-2: скрытая (stories / topology-hidden) непрочитанная не увеличивает число.
  // AC:RL-app-badge-native-visible-count/2
  test('скрытые stories/topology непрочитанные не идут в число', () async {
    final base = AppBadge.visibleUnreadCount(client)!;
    await joinUnreadRoom(
      '!stories:example.invalid',
      createContent: {'com.liza.chat.type': 'stories'},
      notificationCount: 3,
    );
    await joinUnreadRoom(
      '!disc:example.invalid',
      topologyContent: const {'hidden': true},
    );
    expect(AppBadge.visibleUnreadCount(client), base);
  });

  // AC-3: invite в обычную комнату считается (+1), в скрытую — нет.
  // AC:RL-app-badge-native-visible-count/3
  test('invite: обычная считается (+1), скрытая нет', () async {
    final base = AppBadge.visibleUnreadCount(client)!;
    await inviteRoom('!inv:example.invalid');
    await inviteRoom(
      '!inv-hidden:example.invalid',
      createContent: {'com.liza.chat.type': 'stories'},
    );
    expect(AppBadge.visibleUnreadCount(client), base + 1);
  });

  // AC-5 (Android/writer red-proof): refreshFrom персистит в App Group КЛИЕНТСКОЕ
  // число (base+1), а не серверное (base+3). Проверяем через мок нативного канала.
  // AC:RL-app-badge-native-visible-count/5
  test('refreshFrom персистит клиентское число, а не серверное', () async {
    final base = AppBadge.visibleUnreadCount(client)!;
    await joinUnreadRoom('!normal:example.invalid');
    await joinUnreadRoom(
      '!s1:example.invalid',
      createContent: {'com.liza.chat.type': 'stories'},
    );
    await joinUnreadRoom(
      '!s2:example.invalid',
      createContent: {'com.liza.chat.type': 'stories'},
    );
    await AppBadge.refreshFrom(client);
    expect(persistedBadge, base + 1);
  });

  // AC-7: до первого sync (prevBatch == null) число = null → writer НЕ пишет
  // (иначе занизил бы бейдж нулём из фонового изолята без состояния).
  // AC:RL-app-badge-native-visible-count/7
  test('несинканный клиент (prevBatch==null) → число null, App Group не тронут',
      () async {
    final fresh = await prepareTestClient(loggedIn: false);
    addTearDown(() => fresh.dispose(closeDatabase: true));
    expect(fresh.prevBatch, isNull, reason: 'предусловие: ни одного sync');
    expect(AppBadge.visibleUnreadCount(fresh), isNull);
    persistedBadge = null;
    await AppBadge.refreshFrom(fresh);
    expect(persistedBadge, isNull, reason: 'writer не пишет без sync');
  });
}
