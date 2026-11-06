// Точка «в сети» в списке чатов (Надежда Розенталь, 05.11): рядом с аватаром
// небольшая точка цвета плашки «ИИ» у онлайн-человека. Страж на РЕАЛЬНОМ
// ChatListItem, мультикейсный (∀ онлайн / оффлайн / бот / группа / чат с собой).
//
// ledger:RL-chat-list-online-dot

// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/test_client.dart';

const _human = '@human:example.invalid';
const _bot = '@liza:example.invalid';

void main() {
  late Client client;
  late SharedPreferences store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    store = await SharedPreferences.getInstance();
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.showPresences.setItem(true);
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  Event member(Room room, String mxid, String name) => Event(
    eventId: '\$m-$mxid',
    senderId: mxid,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
    type: EventTypes.RoomMember,
    content: {'membership': 'join', 'displayname': name},
    room: room,
    stateKey: mxid,
  );

  Room dm(String peer) {
    final room = Room(id: '!dm-$peer', client: client);
    client.rooms.add(room);
    room.setState(member(room, peer, 'Собеседник'));
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        peer: ['!dm-$peer'],
      },
    );
    return room;
  }

  void presence(String id, PresenceType type) {
    // ignore: deprecated_member_use
    client.presences[id] = CachedPresence(type, 1000, null, true, id);
  }

  Future<void> pump(WidgetTester tester, Room room) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: const [
          L10n.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10n.supportedLocales,
        home: Matrix(
          clients: [client],
          store: store,
          child: Scaffold(body: ChatListItem(room, onTap: () {})),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  final dotFinder = find.byWidgetPredicate(
    (w) => w.key.toString().contains('chatListOnlineDot:'),
  );

  testWidgets('онлайн-человек в DM: точка #4CAF50, ~12px '
      'AC:RL-chat-list-online-dot/1', (tester) async {
    presence(_human, PresenceType.online);
    await pump(tester, dm(_human));

    expect(dotFinder, findsOneWidget);
    final box = tester.widget<Container>(
      find.descendant(of: dotFinder, matching: find.byType(Container)).first,
    );
    expect((box.decoration! as BoxDecoration).color, const Color(0xFF4CAF50));
    final size = tester.getSize(dotFinder);
    expect(size.width, inInclusiveRange(10, 14));
    expect(size.height, size.width);
    await unmount(tester);
  });

  for (final type in [PresenceType.offline, PresenceType.unavailable]) {
    testWidgets('DM, presence=$type: точки нет '
        'AC:RL-chat-list-online-dot/2', (tester) async {
      presence(_human, type);
      await pump(tester, dm(_human));
      expect(dotFinder, findsNothing);
      await unmount(tester);
    });
  }

  testWidgets('DM без записи presence: точки нет '
      'AC:RL-chat-list-online-dot/2', (tester) async {
    await pump(tester, dm(_human));
    expect(dotFinder, findsNothing);
    await unmount(tester);
  });

  testWidgets('бот/ИИ в сети: точки нет AC:RL-chat-list-online-dot/3', (
    tester,
  ) async {
    presence(_bot, PresenceType.online);
    await pump(tester, dm(_bot));
    expect(dotFinder, findsNothing);
    await unmount(tester);
  });

  testWidgets('чат с собой: точки нет AC:RL-chat-list-online-dot/4', (
    tester,
  ) async {
    presence(client.userID!, PresenceType.online);
    await pump(tester, dm(client.userID!));
    expect(dotFinder, findsNothing);
    await unmount(tester);
  });

  testWidgets('группа, даже если участник онлайн: точки нет '
      'AC:RL-chat-list-online-dot/5', (tester) async {
    presence(_human, PresenceType.online);
    final room = Room(id: '!group', client: client);
    client.rooms.add(room);
    room.setState(member(room, _human, 'Участник'));
    room.setState(
      Event(
        eventId: '\$name',
        senderId: _human,
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomName,
        content: const {'name': 'Группа'},
        room: room,
        stateKey: '',
      ),
    );
    await pump(tester, room);
    expect(dotFinder, findsNothing);
    await unmount(tester);
  });

  testWidgets('смена presence перерисовывает точку без сети '
      'AC:RL-chat-list-online-dot/6', (tester) async {
    presence(_human, PresenceType.offline);
    await pump(tester, dm(_human));
    expect(dotFinder, findsNothing);

    client.onPresenceChanged.add(
      CachedPresence(PresenceType.online, 1000, null, true, _human),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(dotFinder, findsOneWidget);

    client.onPresenceChanged.add(
      CachedPresence(PresenceType.offline, 1000, null, false, _human),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    expect(dotFinder, findsNothing);
    await unmount(tester);
  });

  testWidgets('после перезапуска: память presences пуста, статус есть в БД '
      'SDK → точка видна без сети AC:RL-chat-list-online-dot/1', (
    tester,
  ) async {
    await tester.runAsync(
      () => client.database.storePresence(
        _human,
        CachedPresence(PresenceType.online, 1000, null, true, _human),
      ),
    );
    // ignore: deprecated_member_use
    expect(client.presences[_human], isNull);
    await pump(tester, dm(_human));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(dotFinder, findsOneWidget);
    await unmount(tester);
  });

  testWidgets('настройка showPresences выключена: точки нет '
      'AC:RL-chat-list-online-dot/7', (tester) async {
    await AppSettings.showPresences.setItem(false);
    presence(_human, PresenceType.online);
    await pump(tester, dm(_human));
    expect(dotFinder, findsNothing);
    await unmount(tester);
  });
}
