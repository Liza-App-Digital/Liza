// Заявка №60 (решение 02.11): реакции и аватарки прочтения — ОДНА строка под
// пузырём: реакции слева, аватарки справа, одинаково для своих и чужих; строка
// не переносится и при нехватке ширины выходит за край пузыря.
//
// ledger:RL-under-row-reactions-receipts
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/bubble_under_row.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/pages/chat/events/message_reactions.dart';
import 'package:liza/pages/chat/events/seen_by_receipts_sheet.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/room_status_extension.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../../utils/test_client.dart';

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);

  final Client _client;

  @override
  Client get client => _client;
}

const _other = '@roman:example.invalid';
const _short = 'ок';
const _long =
    'Сейчас уже надо по делу писать, иначе никогда не запустим. Пресеты и '
    'поисковую строку переписываем под покупки, а не под всякую всячину — '
    'так, чтобы человек сразу понимал, что тут можно сделать.';

enum _Kind { short, long }

void main() {
  // Догрузка цитат/участников идёт в фоне — закрываем дерево и даём реальное
  // время, иначе таймер/запрос догонит уже закрытую БД.
  void uTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(seconds: 30));
    });
  }

  late Client client;

  Future<void> initClient(WidgetTester tester) async {
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true);
    });
    addTearDown(client.dispose);
  }

  Room buildRoom({String? chatType, bool hide = false}) {
    final room = Room(
      id: '!group:example.invalid',
      client: client,
      membership: Membership.join,
    );
    room.setState(
      StrippedStateEvent(
        type: EventTypes.RoomCreate,
        content: {
          'creator': _other,
          if (chatType != null) 'com.liza.chat.type': chatType,
        },
        senderId: _other,
        stateKey: '',
      ),
    );
    if (hide) {
      room.setState(
        StrippedStateEvent(
          type: hideReadReceiptsState,
          content: {'enabled': true},
          senderId: _other,
          stateKey: '',
        ),
      );
    }
    return room;
  }

  List<MessageReadReceipt> readers(Room room, int n) => [
    for (var i = 0; i < n; i++)
      MessageReadReceipt(User('@reader$i:example.invalid', room: room), i),
  ];

  var bubbleKey = GlobalKey();
  Finder bubble() => find.byKey(bubbleKey);
  Finder reactionsRow() => find.byType(MessageReactions);
  Finder receipts() => find.byType(SeenByAvatars);

  // [reactions]: эмодзи → сколько человек поставили.
  Future<void> pumpOne(
    WidgetTester tester,
    Room room, {
    required bool own,
    required _Kind kind,
    required int n,
    required double width,
    Map<String, int> reactions = const {},
  }) async {
    final sender = own ? client.userID! : _other;
    final target = Event(
      type: EventTypes.Message,
      eventId: '\$target',
      senderId: sender,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(2000),
      content: {
        'msgtype': 'm.text',
        'body': kind == _Kind.long ? _long : _short,
      },
      room: room,
    );
    var ts = 3000;
    final reactionEvents = [
      for (final e in reactions.entries)
        for (var i = 0; i < e.value; i++)
          Event(
            type: EventTypes.Reaction,
            eventId: '\$r${e.key}$i',
            senderId: '@fan$i:example.invalid',
            originServerTs: DateTime.fromMillisecondsSinceEpoch(ts++),
            content: {
              'm.relates_to': {
                'rel_type': RelationshipTypes.reaction,
                'event_id': '\$target',
                'key': e.key,
              },
            },
            room: room,
          ),
    ];
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [...reactionEvents, target], nextBatch: ''),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    bubbleKey = GlobalKey();
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        builder: (context, child) => Provider<liza_matrix.MatrixState>.value(
          value: _TestMatrixState(client),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            controller: scrollController,
            children: [
              Message(
                target,
                timeline: timeline,
                scrollController: scrollController,
                colors: const [Colors.grey, Colors.blue],
                seenByUsers: readers(room, n),
                bubbleKey: bubbleKey,
                onSelect: (_) {},
                onInfoTab: (_) {},
                scrollToEventId: (_) {},
                onSwipe: () {},
                onMention: () {},
                onEdit: () {},
                enterThread: null,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  const twoKinds = [_Kind.short, _Kind.long];
  const sides = [true, false];
  const widths = [360.0, 1280.0];

  // AC:RL-under-row-reactions-receipts/1
  // AC:RL-under-row-reactions-receipts/2
  // Строка уже пузыря (длинное сообщение, 2 читателя, 1 реакция): реакции у
  // левого края пузыря, аватарки у правого, на одном уровне.
  for (final width in widths) {
    for (final own in sides) {
      uTest('реакции слева, аватарки справа, на одном уровне — '
          '${own ? 'своё' : 'чужое'}, ширина $width', (tester) async {
        await initClient(tester);
        await pumpOne(
          tester,
          buildRoom(),
          own: own,
          kind: _Kind.long,
          n: 2,
          width: width,
          reactions: const {'👌': 1},
        );
        final b = tester.getRect(bubble());
        final r = tester.getRect(reactionsRow());
        final c = tester.getRect(receipts());
        expect(r.left, closeTo(b.left, 0.5), reason: 'реакции у левого края');
        expect(c.right, closeTo(b.right, 0.5), reason: 'аватарки у правого');
        expect(r.top, greaterThanOrEqualTo(b.bottom), reason: 'под пузырём');
        expect(c.top, greaterThanOrEqualTo(b.bottom));
        expect(r.center.dy, closeTo(c.center.dy, 1), reason: 'один уровень');
      });
    }
  }

  // AC:RL-under-row-reactions-receipts/3
  // Широкая строка (короткий пузырь «ок», 5 эмодзи, 10 читателей): строка
  // выходит за край пузыря — у чужих вправо, у своих влево; иконки у правого
  // края строки; реакции начинаются с её левого края.
  for (final width in widths) {
    for (final own in sides) {
      uTest(
        'широкая строка выходит за пузырь — ${own ? 'своё влево' : 'чужое вправо'}, '
        '$width',
        (tester) async {
          await initClient(tester);
          await pumpOne(
            tester,
            buildRoom(),
            own: own,
            kind: _Kind.short,
            n: 10,
            width: width,
            reactions: const {'👌': 1, '❤️': 2, '🔥': 1, '😂': 1, '👍': 1},
          );
          final b = tester.getRect(bubble());
          final r = tester.getRect(reactionsRow());
          final c = tester.getRect(receipts());
          expect(c.right - r.left, greaterThan(b.width));
          if (own) {
            expect(r.left, lessThan(b.left), reason: 'вылезла влево');
            expect(c.right, closeTo(b.right, 0.5));
          } else {
            expect(r.left, closeTo(b.left, 0.5));
            expect(c.right, greaterThan(b.right), reason: 'вылезла вправо');
          }
        },
      );
    }
  }

  // AC:RL-under-row-reactions-receipts/4
  // Строка не сужает пузырь и не переносит текст: ширина пузыря и размер
  // текста одинаковы без строки и с любым её наполнением.
  for (final width in widths) {
    for (final own in sides) {
      for (final kind in twoKinds) {
        uTest('ширина пузыря и перенос текста не зависят от строки — '
            '${own ? 'своё' : 'чужое'}, ${kind.name}, $width', (tester) async {
          await initClient(tester);
          final room = buildRoom();
          Future<({double bubbleWidth, Size text})> measure(
            int n,
            Map<String, int> reactions,
          ) async {
            await pumpOne(
              tester,
              room,
              own: own,
              kind: kind,
              n: n,
              width: width,
              reactions: reactions,
            );
            return (
              bubbleWidth: tester.getRect(bubble()).width,
              text: tester.getSize(find.textContaining(_short).first),
            );
          }

          final base = await measure(0, const {});
          for (final c in [
            (1, const <String, int>{}),
            (12, const <String, int>{}),
            (0, const {'👌': 1}),
            (12, const {'👌': 3, '❤️': 5, '🔥': 1, '😂': 1, '👍': 1}),
          ]) {
            final m = await measure(c.$1, c.$2);
            expect(m.bubbleWidth, base.bubbleWidth, reason: '$c: ширина');
            expect(m.text, base.text, reason: '$c: текст');
          }
        });
      }
    }
  }

  // AC:RL-under-row-reactions-receipts/5
  // Высота: строка добавляет ОДНУ и ту же высоту при любом числе читателей/
  // реакций (≥1); без строки — прежняя.
  for (final own in sides) {
    uTest('строка добавляет постоянную высоту — ${own ? 'своё' : 'чужое'}', (
      tester,
    ) async {
      await initClient(tester);
      final room = buildRoom();
      Future<double> h(int n, Map<String, int> reactions) async {
        await pumpOne(
          tester,
          room,
          own: own,
          kind: _Kind.short,
          n: n,
          width: 360,
          reactions: reactions,
        );
        return tester.getSize(find.byType(Message)).height;
      }

      final none = await h(0, const {});
      final one = await h(1, const {});
      expect(one, greaterThan(none));
      expect(await h(12, const {}), one, reason: 'иконки: число не влияет');
      final withReaction = await h(0, const {'👌': 1});
      expect(withReaction, greaterThanOrEqualTo(one));
      expect(
        await h(12, const {'👌': 4, '❤️': 1, '🔥': 2}),
        withReaction,
        reason: 'реакции+иконки: число не влияет',
      );
    });
  }

  // AC:RL-under-row-reactions-receipts/6
  for (final c in const [
    (n: 1, avatars: 1, plus: null),
    (n: 3, avatars: 3, plus: null),
    (n: 10, avatars: 10, plus: null),
    (n: 12, avatars: 10, plus: '+2'),
  ]) {
    uTest('видимые аватарки при ${c.n} читателях', (tester) async {
      await initClient(tester);
      await pumpOne(
        tester,
        buildRoom(),
        own: false,
        kind: _Kind.short,
        n: c.n,
        width: 1280,
      );
      final cluster = receipts();
      expect(cluster, findsOneWidget);
      expect(
        find.descendant(of: cluster, matching: find.byType(Positioned)),
        findsNWidgets(c.avatars + (c.plus == null ? 0 : 1)),
      );
      final box = tester.getSize(cluster);
      expect(
        box.width,
        kSeenAvatarSize +
            (c.avatars + (c.plus == null ? 0 : 1) - 1) * kSeenAvatarStep,
      );
      if (c.plus != null) {
        expect(
          find.descendant(of: cluster, matching: find.text(c.plus!)),
          findsOneWidget,
        );
      }
    });
  }

  // AC:RL-under-row-reactions-receipts/7
  uTest('тап по кластеру открывает список «кто прочитал»', (tester) async {
    await initClient(tester);
    await pumpOne(
      tester,
      buildRoom(),
      own: false,
      kind: _Kind.short,
      n: 2,
      width: 1280,
    );
    await tester.tap(receipts());
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReadReceiptsList), findsOneWidget);
  });

  // AC:RL-under-row-reactions-receipts/8
  for (final c in const [
    (name: 'Liza News (hide_read_receipts)', hide: true, channel: false),
    (name: 'канал', hide: false, channel: true),
  ]) {
    uTest('${c.name}: аватарок прочтения нет', (tester) async {
      await initClient(tester);
      await pumpOne(
        tester,
        buildRoom(hide: c.hide, chatType: c.channel ? channelChatType : null),
        own: false,
        kind: _Kind.long,
        n: 3,
        width: 360,
      );
      expect(receipts(), findsNothing);
    });
  }

  // AC:RL-under-row-reactions-receipts/9
  // 1–3 реагировавших одним эмодзи — аватарками, от 4 — числом.
  for (final c in const [
    (people: 1, avatars: 1),
    (people: 2, avatars: 2),
    (people: 3, avatars: 3),
    (people: 4, avatars: 0),
    (people: 7, avatars: 0),
  ]) {
    uTest('реакция ${c.people} чел.: аватарок ${c.avatars}', (tester) async {
      await initClient(tester);
      await pumpOne(
        tester,
        buildRoom(),
        own: false,
        kind: _Kind.short,
        n: 0,
        width: 1280,
        reactions: {'👌': c.people},
      );
      expect(
        find.descendant(of: reactionsRow(), matching: find.byType(Avatar)),
        findsNWidgets(c.avatars),
      );
      if (c.people > 3) {
        expect(
          find.descendant(
            of: reactionsRow(),
            matching: find.text('${c.people}'),
          ),
          findsOneWidget,
        );
      }
    });
  }
}
