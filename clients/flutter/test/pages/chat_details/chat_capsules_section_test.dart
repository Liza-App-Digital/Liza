// ledger:RL-chat-details-capsules
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_details/chat_capsules_section.dart';

import '../../utils/test_client.dart';

void main() {
  late Room room;

  setUpAll(() async {
    final client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!group:example.org', client: client);
  });

  Widget wrap(ChatCapsulesLoader loader) => MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('ru'),
    home: Scaffold(
      body: SingleChildScrollView(
        child: ChatCapsulesSection(room: room, loader: loader),
      ),
    ),
  );

  testWidgets(
    'капсулы чата показаны списком со ссылкой на все [AC:RL-chat-details-capsules/1]',
    (tester) async {
      final items = [
        for (var i = 1; i <= 7; i++)
          ChatCapsule(
            id: 'c$i',
            title: 'Планёрка $i',
            startedAt: DateTime.utc(2026, 10, 28, 7),
            durationSec: 2110,
          ),
      ];
      await tester.pumpWidget(
        wrap((_) async => ChatCapsules('capsules', items)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Капсулы созвонов'), findsOneWidget);
      expect(find.text('Планёрка 1'), findsOneWidget);
      expect(find.text('Планёрка 5'), findsOneWidget);
      // Больше пяти не показываем — остальные в мини-аппе.
      expect(find.text('Планёрка 6'), findsNothing);
      expect(find.text('Все капсулы чата (7)'), findsOneWidget);
      expect(find.textContaining('36 мин'), findsNWidgets(5));
    },
  );

  testWidgets(
    'капсул нет — раздел есть, с пустым текстом [AC:RL-chat-details-capsules/2]',
    (tester) async {
      await tester.pumpWidget(
        wrap((_) async => const ChatCapsules('capsules', [])),
      );
      await tester.pumpAndSettle();
      expect(find.text('Капсул в этом чате пока нет.'), findsOneWidget);
      expect(find.text('Все капсулы чата (0)'), findsOneWidget);
    },
  );

  testWidgets(
    'капсулы выключены или нет почты — раздела нет [AC:RL-chat-details-capsules/3]',
    (tester) async {
      await tester.pumpWidget(wrap((_) async => null));
      await tester.pumpAndSettle();
      expect(find.text('Капсулы созвонов'), findsNothing);
    },
  );

  test('разбор ответа liza-bot-api [AC:RL-chat-details-capsules/3]', () {
    final ok = parseChatCapsules({
      'app_id': 'capsules',
      'capsules': [
        {
          'id': 'c1',
          'title': 'Планёрка',
          'started_at': '2026-10-28T07:00:00Z',
          'duration_sec': 2110,
        },
        {'title': 'без id'},
        'мусор',
      ],
    })!;
    expect(ok.items.map((c) => c.id), ['c1']);
    expect(ok.items.single.startedAt, DateTime.utc(2026, 10, 28, 7));
    expect(
      parseChatCapsules({
        'app_id': 'capsules',
        'capsules': [],
        'reason': 'no_email',
      }),
      isNull,
    );
    expect(parseChatCapsules({'capsules': []}), isNull);
  });
}
