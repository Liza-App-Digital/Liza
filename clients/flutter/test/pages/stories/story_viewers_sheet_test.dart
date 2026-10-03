// ignore_for_file: depend_on_referenced_packages

// ledger:RL-stories-reactions
//
// LABA-2616: лист «Просмотры» своей сторис — зрители сегмента с эмодзи их
// реакций, отреагировавшие сверху. Рендер РЕАЛЬНОГО прод-виджета.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/stories/story_viewers_sheet.dart';
import 'package:liza/utils/stories/story_reactions.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/test_client.dart';

const _roomId = '!stories:example.invalid';

void main() {
  late Client client;
  late SharedPreferences store;
  late Room room;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    store = await SharedPreferences.getInstance();
    room = Room(id: _roomId, client: client);
    client.rooms = [...client.rooms, room];
    for (final (id, name) in const [
      ('@b:x', 'Борис'),
      ('@c:x', 'Света'),
      ('@d:x', 'Дина'),
    ]) {
      room.setState(
        Event(
          type: EventTypes.RoomMember,
          stateKey: id,
          content: {'membership': 'join', 'displayname': name},
          senderId: id,
          eventId: '\$member_$id',
          originServerTs: DateTime.now(),
          room: room,
        ),
      );
    }
  });

  tearDown(() => client.dispose(closeDatabase: true));

  Future<void> pumpSheet(WidgetTester tester, List<StoryViewerRow> rows) async {
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
          child: Scaffold(
            body: StoryViewersList(room: room, rows: rows),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets('AC:RL-stories-reactions/3 B ❤️, C 😂 сверху, D ниже без '
      'эмодзи; заголовок и число зрителей', (tester) async {
    final rows = storyViewerRows(
      viewers: const ['@d:x', '@b:x', '@c:x'],
      reactions: {
        r'$rb': (sender: '@b:x', target: r'$s1', key: '❤️'),
        r'$rc': (sender: '@c:x', target: r'$s1', key: '😂'),
      },
      segmentId: r'$s1',
    );
    await pumpSheet(tester, rows);

    expect(find.text('Просмотры'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(
      [for (final t in tiles) (t.title as Text).data],
      ['Борис', 'Света', 'Дина'],
    );
    expect(
      [for (final t in tiles) (t.trailing as Text?)?.data],
      ['❤️', '😂', null],
    );
    await teardown(tester);
  });

  testWidgets('пустой сегмент — «Пока никто не посмотрел»', (tester) async {
    await pumpSheet(tester, const []);
    expect(find.text('Пока никто не посмотрел'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await teardown(tester);
  });
}
