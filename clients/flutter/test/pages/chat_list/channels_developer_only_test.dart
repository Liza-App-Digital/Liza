// ledger:RL-channels-developer-only
// guard.render:pure-function — roomVisibleForRole и showChannels чипа.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/chat_list_filter_row.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/developer_mark.dart';
import '../../utils/test_client.dart';

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() async => client.dispose());

  Room roomOfType(String id, String? type) {
    final room = Room(id: id, client: client);
    room.setState(
      Event(
        type: EventTypes.RoomCreate,
        eventId: '\$create$id',
        senderId: '@alice:example.invalid',
        originServerTs: DateTime.now(),
        content: {if (type != null) 'com.liza.chat.type': type},
        stateKey: '',
        room: room,
      ),
    );
    return room;
  }

  // AC:RL-channels-developer-only/2
  test(
    'AC-2: канал и чат-обсуждение видны только developer, прочее — всем',
    () {
      final channel = roomOfType('!c:x', 'channel');
      final discussion = roomOfType('!d:x', 'channel_discussion');
      final group = roomOfType('!g:x', null);
      for (final dev in [true, false]) {
        expect(roomVisibleForRole(channel, isDeveloper: dev), dev);
        expect(roomVisibleForRole(discussion, isDeveloper: dev), dev);
        expect(roomVisibleForRole(group, isDeveloper: dev), isTrue);
      }
    },
  );

  // AC:RL-channels-developer-only/3
  testWidgets('AC-3: чип «Каналы» есть только при showChannels', (t) async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferences.getInstance();
    for (final show in [true, false]) {
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('ru'),
          home: Scaffold(
            body: ChatListFilterRow(
              activeFilter: ActiveFilter.allChats,
              onSelected: (_) {},
              store: store,
              userId: '@a:x',
              showChannels: show,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Каналы'), show ? findsOneWidget : findsNothing);
      expect(find.text('Группы'), findsOneWidget);
    }
  });

  // AC:RL-channels-developer-only/5
  testWidgets('AC-5: чип «Каналы» несёт DeveloperMark', (t) async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferences.getInstance();
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        home: Scaffold(
          body: ChatListFilterRow(
            activeFilter: ActiveFilter.allChats,
            onSelected: (_) {},
            store: store,
            userId: '@a:x',
            developerMark: true,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.widgetWithText(FilterChip, 'Каналы'),
        matching: find.byType(DeveloperMark),
      ),
      findsOneWidget,
    );
    expect(find.byType(DeveloperMark), findsOneWidget);
  });
}
