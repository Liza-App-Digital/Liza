// Заявка №60: аватарки «прочитал до сюда» стоят СБОКУ от пузыря и не меняют
// ни высоту строки ленты, ни ширину пузыря — переезд границы чтения больше не
// сдвигает сообщения под глазами читающего.
// Спека: docs/superpowers/specs/2026-10-28-ticket60-read-receipts-side-and-action-proof-design.md
//
// ledger:RL-receipts-side-no-height
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/bubble_receipts_side.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/pages/chat/events/seen_by_receipts_sheet.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/room_status_extension.dart';
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

enum _Kind { short, long, reply, reactions }

void main() {
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

  // Видимый пузырь — ближайший к тексту RepaintBoundary с bubbleKey.
  // Видимый пузырь — RepaintBoundary(key: bubbleKey), как в ленте чата.
  var bubbleKey = GlobalKey();
  Finder bubble() => find.byKey(bubbleKey);

  // Один Message заданного вида шириной [width] с [n] читателями.
  Future<void> pumpOne(
    WidgetTester tester,
    Room room, {
    required bool own,
    required _Kind kind,
    required int n,
    required double width,
  }) async {
    final sender = own ? client.userID! : _other;
    final body = kind == _Kind.long ? _long : _short;
    final target = Event(
      type: EventTypes.Message,
      eventId: '\$target',
      senderId: sender,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(2000),
      content: {
        'msgtype': 'm.text',
        'body': body,
        if (kind == _Kind.reply)
          'm.relates_to': {
            'm.in_reply_to': {'event_id': '\$quoted'},
          },
      },
      room: room,
    );
    final quoted = Event(
      type: EventTypes.Message,
      eventId: '\$quoted',
      senderId: _other,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
      content: {'msgtype': 'm.text', 'body': 'цитата'},
      room: room,
    );
    final reaction = Event(
      type: EventTypes.Reaction,
      eventId: '\$reaction',
      senderId: _other,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(3000),
      content: {
        'm.relates_to': {
          'rel_type': RelationshipTypes.reaction,
          'event_id': '\$target',
          'key': '👌',
        },
      },
      room: room,
    );
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(
        events: [if (kind == _Kind.reactions) reaction, target, quoted],
        nextBatch: '',
      ),
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
        // Provider над Navigator: шит «кто прочитал» открывается своим
        // маршрутом и тоже читает Matrix.of(context).
        builder: (context, child) => Provider<liza_matrix.MatrixState>.value(
          value: _TestMatrixState(client),
          child: child!,
        ),
        home: Scaffold(
          // BubbleBackground своего пузыря требует Scrollable-предка.
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

  ({Size message, Rect bubble, Size text}) measure(WidgetTester tester) => (
    message: tester.getSize(find.byType(Message)),
    bubble: tester.getRect(bubble()),
    text: tester.getSize(find.textContaining(_short).first),
  );

  // AC:RL-receipts-side-no-height/1
  // AC:RL-receipts-side-no-height/2
  for (final width in const [360.0, 1280.0]) {
    for (final own in const [true, false]) {
      for (final kind in _Kind.values) {
        testWidgets(
          'высота строки и ширина пузыря не зависят от числа читателей — '
          '${own ? 'своё' : 'чужое'}, ${kind.name}, ширина $width',
          (tester) async {
            await initClient(tester);
            final room = buildRoom();
            await pumpOne(
              tester,
              room,
              own: own,
              kind: kind,
              n: 0,
              width: width,
            );
            // Второй кадр с теми же данными: цитата reply догружается
            // асинхронно, база должна мериться по уже стабильной строке.
            await pumpOne(
              tester,
              room,
              own: own,
              kind: kind,
              n: 0,
              width: width,
            );
            final base = measure(tester);
            // 3+ читателей — ревью 28.10: слот рос и сужал пузырь в группах.
            for (final n in const [1, 2, 3, 6, 12]) {
              await pumpOne(
                tester,
                room,
                own: own,
                kind: kind,
                n: n,
                width: width,
              );
              final m = measure(tester);
              expect(
                m.message.height,
                base.message.height,
                reason: 'Δh строки при $n читателях',
              );
              expect(
                m.bubble.width,
                base.bubble.width,
                reason: 'Δw пузыря при $n читателях',
              );
              expect(
                m.text,
                base.text,
                reason: 'перенос текста при $n читателях',
              );
            }
            // Догрузка цитаты reply читает участника из БД в фоне — даём
            // реальное время, иначе запрос догонит уже закрытую БД.
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 300)),
            );
            await tester.pump(const Duration(seconds: 30));
          },
        );
      }
    }
  }

  // AC:RL-receipts-side-no-height/3
  // AC:RL-receipts-side-no-height/4
  // AC:RL-receipts-side-no-height/5
  for (final width in const [360.0, 1280.0]) {
    for (final own in const [true, false]) {
      for (final kind in const [_Kind.short, _Kind.long]) {
        testWidgets(
          'кластер вплотную сбоку у низа пузыря — '
          '${own ? 'своё (слева)' : 'чужое (справа)'}, ${kind.name}, $width',
          (tester) async {
            await initClient(tester);
            await pumpOne(
              tester,
              buildRoom(),
              own: own,
              kind: kind,
              n: 2,
              width: width,
            );
            final b = tester.getRect(bubble());
            final c = tester.getRect(find.byType(SeenByAvatars));
            if (own) {
              expect(c.right, lessThanOrEqualTo(b.left));
              expect(b.left - c.right, lessThanOrEqualTo(6));
            } else {
              expect(c.left, greaterThanOrEqualTo(b.right));
              expect(c.left - b.right, lessThanOrEqualTo(6));
            }
            expect((c.bottom - b.bottom).abs(), lessThanOrEqualTo(2));
            expect(c.left, greaterThanOrEqualTo(0));
            expect(c.right, lessThanOrEqualTo(width));
          },
        );
      }
    }
  }

  // AC:RL-receipts-side-no-height/6
  for (final c in const [
    (n: 1, avatars: 1, plus: null),
    (n: 3, avatars: 3, plus: null),
    (n: 12, avatars: 10, plus: '+2'),
  ]) {
    testWidgets('видимые аватарки при ${c.n} читателях', (tester) async {
      await initClient(tester);
      await pumpOne(
        tester,
        buildRoom(),
        own: false,
        kind: _Kind.short,
        n: c.n,
        width: 1280,
      );
      final cluster = find.byType(SeenByAvatars);
      expect(cluster, findsOneWidget);
      expect(
        find.descendant(of: cluster, matching: find.byType(Positioned)),
        findsNWidgets(c.avatars + (c.plus == null ? 0 : 1)),
      );
      if (c.plus != null) {
        expect(
          find.descendant(of: cluster, matching: find.text(c.plus!)),
          findsOneWidget,
        );
      }
    });
  }

  // AC:RL-receipts-side-no-height/7
  testWidgets('тап по кластеру открывает список «кто прочитал»', (
    tester,
  ) async {
    await initClient(tester);
    await pumpOne(
      tester,
      buildRoom(),
      own: false,
      kind: _Kind.short,
      n: 2,
      width: 1280,
    );
    await tester.tap(find.byType(SeenByAvatars));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReadReceiptsList), findsOneWidget);
  });

  // AC:RL-receipts-side-no-height/8
  for (final c in const [
    (name: 'Liza News (hide_read_receipts)', hide: true, channel: false),
    (name: 'канал', hide: false, channel: true),
  ]) {
    testWidgets('${c.name}: нет ни аватарок, ни бокового слота', (
      tester,
    ) async {
      await initClient(tester);
      await pumpOne(
        tester,
        buildRoom(hide: c.hide, chatType: c.channel ? channelChatType : null),
        own: false,
        kind: _Kind.long,
        n: 3,
        width: 360,
      );
      expect(find.byType(SeenByAvatars), findsNothing);
      final bubbleRect = tester.getRect(bubble());
      // Слота нет: длинный пузырь доходит до правого края ряда (отступ
      // контейнера ряда 8 px), а не обрывается на ширину слота раньше.
      expect(360 - bubbleRect.right, lessThan(kReceiptsSideMinWidth));
    });
  }

  // AC:RL-receipts-side-no-height/6
  group('fitSeenAvatars: не влезает — сжимаем шаг, потом «+N»', () {
    test('места хватает — шаг 11, все до лимита', () {
      final f = fitSeenAvatars(total: 3, maxShown: 3, maxWidth: 200);
      expect(f.step, kSeenAvatarStep);
      expect(f.shown, 3);
    });
    test('мало места — шаг сжимается, аватарки не теряются', () {
      final f = fitSeenAvatars(total: 4, maxShown: 4, maxWidth: 40);
      expect(f.shown, 4);
      expect(16 + 3 * f.step, lessThanOrEqualTo(40));
      expect(f.step, greaterThanOrEqualTo(kSeenAvatarMinStep));
    });
    test('совсем мало места — лишние уходят в «+N», ширина в пределах', () {
      final f = fitSeenAvatars(total: 12, maxShown: 10, maxWidth: 27);
      final slots = f.shown + (12 > f.shown ? 1 : 0);
      expect(16 + (slots - 1) * f.step, lessThanOrEqualTo(27));
      expect(f.shown, lessThan(10));
    });
  });
}
