// ledger:RL-emoji-history-search
// guard.render:real-widget — прод EmojiQuickReactions/InputBar; методы
// ChatController вызываются напрямую, подменяется только граница Room.sendReaction.
import 'dart:async';
import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/chat_emoji_picker.dart';
import 'package:liza/pages/chat/input_bar.dart';
import 'package:liza/utils/emoji_history_store.dart';
import 'package:liza/widgets/emoji_quick_reactions.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

const _defaults = ['👍', '❤️', '😁', '🔥', '👏'];
const _choices = ['🐈', '👩🏽‍💻', '🇷🇺', '🎯', '🍏', '🚀', '🌈', '🎉'];

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('ru'),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Scaffold(body: child),
);

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client, this._store);
  final Client _client;
  final SharedPreferences _store;
  @override
  Client get client => _client;
  @override
  SharedPreferences get store => _store;
}

// Инициализация всего экрана чата здесь не нужна. Не переопределяем typeEmoji,
// toggleReaction, emojiHistoryFor и insertion — это именно прод-пути.
class _TestChatController extends ChatController {
  _TestChatController(this._room, this._context);
  Room _room;
  final BuildContext _context;
  @override
  Room get room => _room;
  @override
  String get roomId => _room.id;
  @override
  BuildContext get context => _context;
}

class _ReactionRoom extends Room {
  _ReactionRoom(Client client)
    : super(id: '!emoji:example.invalid', client: client);
  Future<String?> Function() result = () async => r'$reaction';
  var sent = 0;
  var redacted = 0;

  @override
  Future<String?> sendReaction(String eventId, String key, {String? txid}) {
    sent++;
    return result();
  }

  @override
  Future<String?> redactEvent(
    String eventId, {
    String? reason,
    String? txid,
  }) async {
    redacted++;
    return r'$redaction';
  }
}

int _count(EmojiHistoryStore history, String emoji) {
  final encoded = history.prefs.getString(history.storageKey);
  if (encoded == null) return 0;
  final data = jsonDecode(encoded) as Map<String, dynamic>;
  return (data['entries'] as List)
      .where((e) => e['emoji'] == emoji)
      .fold<int>(0, (sum, entry) => sum + (entry['count'] as int));
}

List<String> _visible(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byType(EmojiQuickReactions),
        matching: find.byType(Text),
      ),
    )
    .map((text) => text.data!)
    .toList();

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('AC:RL-emoji-history-search/3 — быстрая полоска', () {
    for (final count in [0, 1, 5, 8]) {
      testWidgets('$count в истории: пять уникальных и полный выбор', (
        tester,
      ) async {
        final history = EmojiHistoryStore(prefs, '@a:one', EmojiUsage.reaction);
        for (final emoji in _choices.take(count)) {
          await history.record(emoji);
        }
        final selected = <String>[];
        var more = 0;
        await tester.pumpWidget(
          _app(
            EmojiQuickReactions(
              history: history,
              defaults: _defaults,
              sentReactions: const {},
              onSelected: selected.add,
              onMore: () => more++,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final expected = <String>{
          ..._choices.take(count).toList().reversed,
          ..._defaults,
        }.take(5).toList();
        // AC:RL-emoji-history-search/3 — реальные кнопки, ∀ 0/1/5/8.
        expect(_visible(tester), expected);
        expect(_visible(tester).toSet(), hasLength(5));
        expect(find.byType(IconButton), findsNWidgets(6));
        for (final emoji in expected) {
          await tester.tap(find.text(emoji));
        }
        expect(selected, expected);
        await tester.tap(find.byIcon(Icons.add_reaction_outlined));
        expect(more, 1);
      });
    }

    testWidgets('snapshot не прыгает; новое открытие и аккаунт обновляют его', (
      tester,
    ) async {
      final a = EmojiHistoryStore(prefs, '@a:one', EmojiUsage.reaction);
      final b = EmojiHistoryStore(prefs, '@a:two', EmojiUsage.reaction);
      await a.record('🐈');
      await b.record('🇷🇺');
      Widget quick(EmojiHistoryStore history) => _app(
        EmojiQuickReactions(
          history: history,
          defaults: _defaults,
          sentReactions: const {},
          onSelected: (_) {},
          onMore: () {},
        ),
      );
      await tester.pumpWidget(quick(a));
      await tester.pumpAndSettle();
      final before = _visible(tester);
      await a.record('👩🏽‍💻');
      await tester.pumpWidget(
        quick(EmojiHistoryStore(prefs, '@a:one', EmojiUsage.reaction)),
      );
      expect(_visible(tester), before);
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pumpWidget(quick(a));
      expect(_visible(tester).first, '👩🏽‍💻');
      await tester.pumpWidget(quick(b));
      expect(_visible(tester).first, '🇷🇺');
      expect(_visible(tester), isNot(contains('🐈')));
      expect(_visible(tester), isNot(contains('👩🏽‍💻')));
      // AC:RL-emoji-history-search/6 — показ/перестройка/закрытие без выбора.
      expect(_count(a, '🐈'), 1);
      expect(_count(a, '👩🏽‍💻'), 1);
    });
  });

  group('реальный композер и контроллер', () {
    late Client client;
    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
      client.backgroundSync = false;
    });
    tearDown(() async => client.dispose(closeDatabase: true));

    Future<BuildContext> provide(WidgetTester tester, Widget child) async {
      late BuildContext result;
      await tester.pumpWidget(
        _app(
          Provider<liza_matrix.MatrixState>.value(
            value: _TestMatrixState(client, prefs),
            child: Builder(
              builder: (context) {
                result = context;
                return child;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets(
      'AC:RL-emoji-history-search/5 — тап настоящей :keyword вставляет один раз',
      (tester) async {
        final text = TextEditingController();
        final focus = FocusNode();
        addTearDown(text.dispose);
        addTearDown(focus.dispose);
        await provide(
          tester,
          InputBar(
            room: Room(id: '!selected:example.invalid', client: client),
            controller: text,
            focusNode: focus,
            minLines: 1,
            maxLines: 5,
            decoration: const InputDecoration(),
            suggestionEmojis: const [Emoji('👩🏽‍💻', 'technologist')],
            keyboardType: TextInputType.multiline,
            autofocus: false,
            onChanged: (_) {},
          ),
        );
        final history = EmojiHistoryStore(
          prefs,
          client.userID!,
          EmojiUsage.text,
        );
        await tester.enterText(find.byType(TextField), 'до :tech');
        await tester.pumpAndSettle();
        expect(find.text('technologist'), findsOneWidget);
        expect(history.ranked(), isEmpty);
        await tester.tap(find.text('technologist'));
        await tester.pumpAndSettle();
        // AC:RL-emoji-history-search/5; AC:RL-emoji-history-search/6.
        expect(text.text, 'до 👩🏽‍💻 ');
        expect(_count(history, '👩🏽‍💻'), 1);
      },
    );

    testWidgets(
      'AC:RL-emoji-history-search/5 — typeEmoji вставляет Unicode и null отменяет',
      (tester) async {
        final context = await provide(tester, const SizedBox());
        final controller = _TestChatController(
          Room(id: '!type:example.invalid', client: client),
          context,
        );
        addTearDown(controller.sendController.dispose);
        final history = EmojiHistoryStore(
          prefs,
          client.userID!,
          EmojiUsage.text,
        );
        for (final emoji in ['👍🏽', '👩🏽‍💻', '🇷🇺']) {
          controller.sendController.value = const TextEditingValue(
            text: 'до после',
            selection: TextSelection.collapsed(offset: 3),
          );
          controller.typeEmoji(Emoji(emoji, 'test'));
          await tester.pumpAndSettle();
          expect(controller.sendController.text, 'до $emojiпосле');
          expect(_count(history, emoji), 1);
          final before = prefs.getString(history.storageKey);
          controller.typeEmoji(null);
          await tester.pumpAndSettle();
          expect(controller.sendController.text, 'до $emojiпосле');
          // AC:RL-emoji-history-search/6 — отмена не увеличивает счётчик.
          expect(prefs.getString(history.storageKey), before);
        }
      },
    );

    testWidgets(
      'AC:RL-emoji-history-search/6 — display чистый, :keyword один раз',
      (tester) async {
        final text = TextEditingController();
        final focus = FocusNode();
        addTearDown(text.dispose);
        addTearDown(focus.dispose);
        await provide(
          tester,
          InputBar(
            room: Room(id: '!composer:example.invalid', client: client),
            controller: text,
            focusNode: focus,
            minLines: 1,
            maxLines: 5,
            decoration: const InputDecoration(),
            suggestionEmojis: const [],
            keyboardType: TextInputType.multiline,
            autofocus: false,
            onChanged: (_) {},
          ),
        );
        final autocomplete = tester
            .widget<RawAutocomplete<Map<String, String?>>>(
              find.byType(RawAutocomplete<Map<String, String?>>),
            );
        final history = EmojiHistoryStore(
          prefs,
          client.userID!,
          EmojiUsage.text,
        );
        for (final emoji in ['👍🏽', '👩🏽‍💻', '🇷🇺']) {
          text.value = const TextEditingValue(
            text: 'до :test',
            selection: TextSelection.collapsed(offset: 8),
          );
          final suggestion = <String, String?>{
            'type': 'emoji',
            'emoji': emoji,
            'current_word': ':test',
          };
          for (var i = 0; i < 3; i++) {
            expect(
              autocomplete.displayStringForOption(suggestion),
              'до $emoji ',
            );
          }
          expect(history.ranked(), isNot(contains(emoji)));
          // Это реальная последовательность RawAutocomplete: display, insertion,
          // onSelected. Берём оба callbacks из смонтированного прод-InputBar.
          text.text = autocomplete.displayStringForOption(suggestion);
          autocomplete.onSelected!(suggestion);
          await tester.pumpAndSettle();
          // AC:RL-emoji-history-search/5 — Unicode вставлен ровно один раз.
          expect(text.text, 'до $emoji ');
          expect(_count(history, emoji), 1);
        }
        final before = prefs.getString(history.storageKey);
        text.value = const TextEditingValue(
          text: ':party',
          selection: TextSelection.collapsed(offset: 6),
        );
        const custom = {'type': 'emote', 'name': 'party', 'pack': 'room'};
        text.text = autocomplete.displayStringForOption(custom);
        autocomplete.onSelected!(custom);
        await tester.pumpAndSettle();
        expect(text.text, ':party: ');
        expect(prefs.getString(history.storageKey), before);
      },
    );

    testWidgets(
      'AC:RL-emoji-history-search/7 — реальный composer picker открывается без overflow',
      (tester) async {
        final context = await provide(tester, const SizedBox());
        final controller = _TestChatController(
          Room(id: '!animated:example.invalid', client: client),
          context,
        );
        late StateSetter rebuild;
        await provide(
          tester,
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  const Expanded(child: SizedBox()),
                  ChatEmojiPicker(controller),
                ],
              );
            },
          ),
        );
        expect(find.byType(ChatEmojiPicker), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (var opening = 0; opening < 2; opening++) {
          rebuild(() => controller.showEmojiPicker = true);
          final errors = <Object>[];
          for (final elapsed in [
            Duration.zero,
            const Duration(milliseconds: 10),
            const Duration(milliseconds: 50),
            const Duration(milliseconds: 300),
          ]) {
            await tester.pump(elapsed);
            final error = tester.takeException();
            if (error != null) errors.add(error);
          }
          await tester.pumpAndSettle();
          final settledError = tester.takeException();
          if (settledError != null) errors.add(settledError);
          // AC:RL-emoji-history-search/7 — каждый промежуточный кадр
          // настоящего ChatEmojiPicker, а не финальная высота/реплика.
          expect(errors, isEmpty, reason: 'открытие $opening: $errors');
          rebuild(() => controller.showEmojiPicker = false);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      'AC:RL-emoji-history-search/6 — in-flight A→B сохраняет исходный аккаунт',
      (tester) async {
        final api = FakeMatrixApi();
        api.api['POST']!['/client/v3/login'] = (_) => {
          'user_id': '@second:fakeServer.notExisting',
          'access_token': 'widget-test-token-b',
          'device_id': 'WIDGETB',
        };
        final otherClient = await tester.runAsync(
          () => prepareTestClient(
            loggedIn: true,
            id: 'Liza pending account B',
            httpClient: api,
          ),
        );
        expect(otherClient, isNotNull);
        otherClient!.backgroundSync = false;
        try {
          expect(
            otherClient.userID,
            isNot(client.userID),
            reason: 'A/B должны иметь разные storage keys, не только Client',
          );
          final context = await provide(tester, const SizedBox());
          final roomA = _ReactionRoom(client);
          final roomB = _ReactionRoom(otherClient);
          final pending = Completer<String?>();
          roomA.result = () => pending.future;
          final event = Event(
            eventId: r'$pendingMessage',
            senderId: '@other:one',
            originServerTs: DateTime(2026),
            type: EventTypes.Message,
            content: {'body': 'test', 'msgtype': 'm.text'},
            room: roomA,
          );
          final timeline = Timeline(
            room: roomA,
            chunk: TimelineChunk(events: [event]),
          );
          addTearDown(timeline.cancelSubscriptions);
          final controller = _TestChatController(roomA, context)
            ..timeline = timeline;
          final historyA = EmojiHistoryStore(
            prefs,
            client.userID!,
            EmojiUsage.reaction,
          );
          final historyB = EmojiHistoryStore(
            prefs,
            otherClient.userID!,
            EmojiUsage.reaction,
          );
          controller.toggleReaction(event, '👩🏽‍💻');
          expect(roomA.sent, 1);
          expect(pending.isCompleted, isFalse);
          expect(_count(historyA, '👩🏽‍💻'), 0);
          expect(_count(historyB, '👩🏽‍💻'), 0);

          // Между вызовом sendReaction и ответом сервера getter уже указывает
          // на новый аккаунт, как после переключения sendingClient в проде.
          controller._room = roomB;
          expect(controller.room.client, same(otherClient));
          pending.complete(r'$successfulReactionOnA');
          await tester.pumpAndSettle();

          // AC:RL-emoji-history-search/6 — исходный MXID захвачен до await.
          expect(_count(historyA, '👩🏽‍💻'), 1);
          expect(_count(historyB, '👩🏽‍💻'), 0);
          expect(roomA.sent, 1);
          expect(roomB.sent, 0);
        } finally {
          await tester.runAsync(() => otherClient.dispose(closeDatabase: true));
        }
      },
    );

    testWidgets(
      'AC:RL-emoji-history-search/6 — add success/null/error и guards',
      (tester) async {
        final context = await provide(tester, const SizedBox());
        final room = _ReactionRoom(client);
        final controller = _TestChatController(room, context);
        final history = EmojiHistoryStore(
          prefs,
          client.userID!,
          EmojiUsage.reaction,
        );
        final event = Event(
          eventId: r'$message',
          senderId: '@other:one',
          originServerTs: DateTime(2026),
          type: EventTypes.Message,
          content: {'body': 'test', 'msgtype': 'm.text'},
          room: room,
        );
        controller.toggleReaction(event, '🐈'); // timeline отсутствует.
        expect(room.sent, 0);
        expect(history.ranked(), isEmpty);
        final timeline = Timeline(
          room: room,
          chunk: TimelineChunk(events: [event]),
        );
        controller.timeline = timeline;
        addTearDown(timeline.cancelSubscriptions);
        controller.toggleReaction(event, '🐈');
        await tester.pumpAndSettle();
        expect(_count(history, '🐈'), 1);
        expect(room.sent, 1);
        final before = prefs.getString(history.storageKey);
        room.result = () async => null;
        controller.toggleReaction(event, '🇷🇺');
        await tester.pumpAndSettle();
        expect(prefs.getString(history.storageKey), before);
        room.result = () async => throw StateError('тестовая ошибка отправки');
        controller.toggleReaction(event, '👩🏽‍💻');
        await tester.pumpAndSettle();
        expect(prefs.getString(history.storageKey), before);
        expect(tester.takeException(), isNull);
        expect(room.sent, 3);
        room.setState(
          Event(
            eventId: r'$power',
            senderId: client.userID!,
            originServerTs: DateTime(2026),
            type: EventTypes.RoomPowerLevels,
            stateKey: '',
            content: {
              'events': {'m.reaction': 100},
            },
            room: room,
          ),
        );
        controller.toggleReaction(event, '🔥');
        await tester.pumpAndSettle();
        expect(room.sent, 3);
        expect(prefs.getString(history.storageKey), before);
        final ownReaction = Event(
          eventId: r'$own',
          senderId: client.userID!,
          originServerTs: DateTime(2026),
          type: EventTypes.Reaction,
          content: {
            'm.relates_to': {
              'rel_type': RelationshipTypes.reaction,
              'event_id': event.eventId,
              'key': '🐈',
            },
          },
          room: room,
        );
        timeline.addAggregatedEvent(ownReaction);
        controller.toggleReaction(event, '🐈');
        await tester.pumpAndSettle();
        expect(room.redacted, 1);
        expect(room.sent, 3);
        expect(prefs.getString(history.storageKey), before);

        final otherClient = await tester.runAsync(
          () => prepareTestClient(loggedIn: true, id: 'Liza stale account'),
        );
        final switched = _TestChatController(
          Room(id: '!other:example.invalid', client: otherClient!),
          context,
        )..timeline = timeline;
        try {
          room.setState(
            Event(
              eventId: r'$powerRestored',
              senderId: client.userID!,
              originServerTs: DateTime(2026),
              type: EventTypes.RoomPowerLevels,
              stateKey: '',
              content: {
                'events': {'m.reaction': 0},
              },
              room: room,
            ),
          );
          room.result = () async => r'$wouldBeSent';
          // Событие старого аккаунта осталось в открытом popover после switch.
          switched.toggleReaction(event, '🎯');
          await tester.pumpAndSettle();
          expect(room.sent, 3);
          expect(prefs.getString(history.storageKey), before);
        } finally {
          await tester.runAsync(() => otherClient.dispose(closeDatabase: true));
        }
      },
    );
  });
}
