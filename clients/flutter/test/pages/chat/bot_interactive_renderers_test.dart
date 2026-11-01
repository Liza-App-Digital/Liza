// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-api-interactive-renderers
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alchemist/alchemist.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/l10n/l10n_ru.dart';
import 'package:liza/pages/chat/events/bot_interactive_content.dart';
import 'package:liza/pages/chat/events/inline_bot_video.dart';
import 'package:liza/pages/chat/events/message_content.dart';
import 'package:liza/pages/chat/events/message_time.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/pages/chat/events/image_bubble.dart';
import 'package:liza/pages/chat/events/video_player.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/widgets/mxc_image.dart';
import 'package:liza/widgets/matrix.dart' as liza;

import '../../utils/test_client.dart';

class _SyncL10n extends LocalizationsDelegate<L10n> {
  const _SyncL10n();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<L10n> load(Locale locale) => SynchronousFuture(L10nRu());
  @override
  bool shouldReload(_SyncL10n old) => false;
}

class _MatrixState extends liza.MatrixState {
  final Client value;
  _MatrixState(this.value);
  @override
  Client get client => value;
}

class _Session implements InlineVideoSession {
  int opens = 0;
  int disposals = 0;
  bool? loop;
  bool? muted;
  Completer<void>? pending;
  Completer<void>? pendingDispose;
  @override
  Widget buildVideo() => const ColoredBox(color: Colors.teal);
  @override
  Future<void> open(
    Event event, {
    required bool loop,
    required bool muted,
  }) async {
    opens++;
    this.loop = loop;
    this.muted = muted;
    await pending?.future;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await pendingDispose?.future;
  }
}

void main() {
  late Client client;
  late Room room;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    client = await prepareTestClient();
    room = Room(id: '!render:example.invalid', client: client);
  });
  tearDownAll(() => client.dispose(closeDatabase: true));

  Event event(Map<String, dynamic> content, {String id = 'event'}) => Event(
    type: EventTypes.Message,
    eventId: '\$$id',
    senderId: '@bot:example.invalid',
    originServerTs: DateTime(2026, 10, 30),
    room: room,
    content: {'msgtype': 'm.text', 'body': 'Readable fallback', ...content},
  );
  Widget wrap(Widget child) => MaterialApp(
    locale: const Locale('ru'),
    localizationsDelegates: [
      const _SyncL10n(),
      ...L10n.localizationsDelegates.skip(1),
    ],
    supportedLocales: L10n.supportedLocales,
    home: Provider<liza.MatrixState>.value(
      value: _MatrixState(client),
      child: Scaffold(body: Center(child: child)),
    ),
  );
  Widget content(Event e) => MessageContent(
    e,
    timeline: Timeline(
      room: room,
      chunk: TimelineChunk(events: [e]),
    ),
    textColor: Colors.black,
    linkColor: Colors.blue,
    borderRadius: BorderRadius.circular(12),
    selected: false,
  );
  Map<String, dynamic> video({Map<String, dynamic>? extra}) => {
    'msgtype': 'm.video',
    'url': 'mxc://example.invalid/motion',
    'info': {'w': 320, 'h': 320, 'mimetype': 'video/mp4'},
    ...?extra,
  };

  testWidgets('контакт — реальные имя/телефон, без Matrix-действия', (
    tester,
  ) async {
    // AC:RL-bot-api-interactive-renderers/1
    await tester.pumpWidget(
      wrap(
        content(
          event({
            'com.liza.contact': {
              'first_name': 'Анна',
              'last_name': 'Иванова',
              'phone_number': '+79990000000',
              'user_id': '@victim:example.invalid',
            },
          }),
        ),
      ),
    );
    expect(find.byType(BotContactContent), findsOneWidget);
    expect(find.text('Анна Иванова'), findsOneWidget);
    expect(find.text('+79990000000'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
    expect(find.text('@victim:example.invalid'), findsNothing);
  });

  testWidgets('dice immutable и malformed metadata → читаемый fallback', (
    tester,
  ) async {
    // AC:RL-bot-api-interactive-renderers/2
    final e = event({
      'com.liza.dice': {'emoji': '🎰', 'value': 64},
    });
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(wrap(content(e)));
      expect(find.text('64'), findsOneWidget);
      expect(find.byType(BotDiceContent), findsOneWidget);
    }
    for (final bad in [0, 65, true, '4', 1.5]) {
      await tester.pumpWidget(
        wrap(
          content(
            event({
              'com.liza.dice': {'emoji': '🎰', 'value': bad},
            }),
          ),
        ),
      );
      expect(find.byType(BotDiceContent), findsNothing);
      expect(
        find.textContaining('Readable fallback', findRichText: true),
        findsWidgets,
      );
    }
    await tester.pumpWidget(
      wrap(
        content(
          event({
            'com.liza.contact': {'phone_number': 123, 'first_name': 'A'},
          }),
        ),
      ),
    );
    expect(find.byType(BotContactContent), findsNothing);
  });

  testWidgets(
    'кружок и live photo используют разные реальные presentation paths',
    (tester) async {
      // AC:RL-bot-api-interactive-renderers/3
      await tester.pumpWidget(
        wrap(
          content(
            event(
              video(
                extra: {
                  'com.liza.video_note': {'duration': 5, 'length': 320},
                },
              ),
            ),
          ),
        ),
      );
      expect(find.byType(ClipOval), findsOneWidget);
      expect(
        tester.widget<InlineBotVideo>(find.byType(InlineBotVideo)).round,
        isTrue,
      );
      final live = event(
        video(
          extra: {
            'com.liza.live_photo': {
              'duration': 5,
              'cover': {
                'url': 'mxc://example.invalid/cover',
                'info': {'w': 320, 'h': 320, 'mimetype': 'image/jpeg'},
              },
            },
          },
        ),
      );
      await tester.pumpWidget(wrap(content(live)));
      expect(find.byType(BotLivePhotoContent), findsOneWidget);
      expect(
        tester.widget<MxcImage>(find.byType(MxcImage)).uri.toString(),
        'mxc://example.invalid/cover',
      );
      expect(
        tester.widget<InlineBotVideo>(find.byType(InlineBotVideo)).autoplay,
        isFalse,
      );
      expect(
        tester.widget<InlineBotVideo>(find.byType(InlineBotVideo)).loop,
        isTrue,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 61));
    },
  );

  testWidgets('один player; offscreen/background/dispose освобождают backend', (
    tester,
  ) async {
    // AC:RL-bot-api-interactive-renderers/4
    final sessions = <_Session>[];
    InlineVideoSession factory() {
      final s = _Session();
      sessions.add(s);
      return s;
    }

    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final e = event(video());
    Widget media(String id) => InlineBotVideo(
      key: ValueKey(id),
      event: e,
      label: 'GIF',
      autoplay: true,
      loop: true,
      sessionFactory: factory,
      poster: const ColoredBox(color: Colors.black),
    );
    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 400,
          child: ListView(
            controller: scroll,
            cacheExtent: 2000,
            children: [
              media('one'),
              media('two'),
              const SizedBox(height: 1000),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(sessions.length, 1);
    expect(sessions.single.opens, 1);
    expect(sessions.single.loop, isTrue);
    expect(sessions.single.muted, isTrue);
    scroll.jumpTo(850);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(sessions.single.disposals, 1);
    expect(find.byType(InlineBotVideo, skipOffstage: false), findsNWidgets(2));
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(sessions.length, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(sessions.last.disposals, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(sessions.every((s) => s.disposals == 1), isTrue);
  });

  testWidgets(
    'dispose во время open не создаёт второй player и не setState после смерти',
    (tester) async {
      final session = _Session()..pending = Completer<void>();
      await tester.pumpWidget(
        wrap(
          InlineBotVideo(
            event: event(video()),
            label: 'GIF',
            autoplay: true,
            sessionFactory: () => session,
            poster: const SizedBox(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpWidget(const SizedBox());
      expect(session.disposals, 1);
      session.pending!.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ручной запуск ждёт полного dispose предыдущего player', (
    tester,
  ) async {
    // AC:RL-bot-api-interactive-renderers/3
    // AC:RL-bot-api-interactive-renderers/4
    final first = _Session()..pendingDispose = Completer<void>();
    final second = _Session();
    Widget media(String id, _Session session) => InlineBotVideo(
      key: ValueKey(id),
      event: event(video(), id: id),
      label: id,
      loop: true,
      poster: Text('cover-$id'),
      sessionFactory: () => session,
    );
    await tester.pumpWidget(
      wrap(Row(children: [media('one', first), media('two', second)])),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(first.opens + second.opens, 0);
    expect(find.text('cover-one'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('one')));
    await tester.pump();
    await tester.pump();
    expect(first.opens, 1);
    expect(first.loop, isTrue);
    expect(first.muted, isTrue);
    await tester.tap(find.byKey(const ValueKey('two')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(first.disposals, 1);
    expect(second.opens, 0, reason: 'lease удерживается до завершения dispose');
    first.pendingDispose!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(second.opens, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(first.disposals, 1);
    expect(second.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TickerMode закрывает player и разрешает новый при возврате', (
    tester,
  ) async {
    // AC:RL-bot-api-interactive-renderers/4
    final sessions = <_Session>[];
    Widget scene(bool enabled) => wrap(
      TickerMode(
        enabled: enabled,
        child: InlineBotVideo(
          event: event(video()),
          label: 'GIF',
          autoplay: true,
          poster: const SizedBox(),
          sessionFactory: () {
            final session = _Session();
            sessions.add(session);
            return session;
          },
        ),
      ),
    );
    await tester.pumpWidget(scene(false));
    await tester.pump(const Duration(milliseconds: 250));
    expect(sessions, isEmpty);
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(sessions.single.opens, 1);
    await tester.pumpWidget(scene(false));
    await tester.pump();
    expect(sessions.single.disposals, 1);
    await tester.pump(const Duration(milliseconds: 250));
    expect(sessions.length, 1);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'MP4 animation учитывает preference; обычное видео остаётся viewer',
    (tester) async {
      // AC:RL-bot-api-interactive-renderers/4
      final animation = event(
        video(
          extra: {
            'info': {
              'w': 320,
              'h': 320,
              'mimetype': 'video/mp4',
              'fi.mau.autoplay': true,
              'fi.mau.loop': true,
              'thumbnail_url': 'mxc://example.invalid/poster',
            },
          },
        ),
      );
      Widget scene(Event e) =>
          wrap(TickerMode(enabled: false, child: EventVideoPlayer(e)));
      await AppSettings.autoplayImages.setItem(false);
      await tester.pumpWidget(scene(animation));
      var inline = tester.widget<InlineBotVideo>(find.byType(InlineBotVideo));
      expect(inline.autoplay, isFalse);
      expect(inline.loop, isTrue);
      expect(inline.muted, isTrue);
      await AppSettings.autoplayImages.setItem(true);
      await tester.pumpWidget(scene(animation));
      inline = tester.widget<InlineBotVideo>(find.byType(InlineBotVideo));
      expect(inline.autoplay, isTrue);
      final normal = event(
        video(
          extra: {
            'info': {
              'w': 320,
              'h': 320,
              'mimetype': 'video/mp4',
              'thumbnail_url': 'mxc://example.invalid/poster',
            },
          },
        ),
      );
      await tester.pumpWidget(scene(normal));
      expect(find.byType(InlineBotVideo), findsNothing);
      expect(find.byType(InkWell), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 61));
    },
  );

  testWidgets('draft metadata — индикатор в реальном footer', (tester) async {
    // AC:RL-bot-api-interactive-renderers/5
    final original = event({
      'com.liza.draft': {
        'draft_id': 1,
        'can_stop': false,
        'keep_on_stop': false,
      },
    });
    expect(isBotDraft(original, original), isTrue);
    expect(isBotDraft(original, event({})), isFalse);
    expect(
      BotDraft.parse({
        'draft_id': true,
        'can_stop': false,
        'keep_on_stop': false,
      }),
      isNull,
    );
    await tester.pumpWidget(
      wrap(
        MessageTime(
          time: '10:20',
          color: Colors.grey,
          isDraft: isBotDraft(original, original),
        ),
      ),
    );
    expect(find.text('Черновик'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });

  testWidgets('обновление draft в реальном Message не показывает изменено', (
    tester,
  ) async {
    // AC:RL-bot-api-interactive-renderers/5
    const meta = {'draft_id': 1, 'can_stop': false, 'keep_on_stop': false};
    final original = event({
      'msgtype': 'm.notice',
      'body': 'Думаю',
      'com.liza.draft': meta,
    });
    final update = event({
      'msgtype': 'm.notice',
      'body': '* Думаю ещё',
      'm.new_content': {
        'msgtype': 'm.notice',
        'body': 'Думаю ещё',
        'com.liza.draft': meta,
      },
      'm.relates_to': {
        'rel_type': RelationshipTypes.edit,
        'event_id': original.eventId,
      },
    }, id: 'edit');
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [update, original]),
    );
    expect(
      original.hasAggregatedEvents(timeline, RelationshipTypes.edit),
      isTrue,
    );
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        wrap(
          ListView(
            controller: scroll,
            children: [
              Message(
                original,
                timeline: timeline,
                scrollController: scroll,
                colors: const [Colors.grey, Colors.blue],
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
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
    expect(find.text('Черновик'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('raw GIF: autoplay preference, viewport и background', (
    tester,
  ) async {
    // AC:RL-bot-api-interactive-renderers/7
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    bool? enabled;
    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 250,
          child: ListView(
            controller: scroll,
            cacheExtent: 2000,
            children: [
              ViewportAnimation(
                child: Builder(
                  builder: (context) {
                    enabled = TickerMode.valuesOf(context).enabled;
                    return const SizedBox(height: 200, width: 200);
                  },
                ),
              ),
              const SizedBox(height: 1000),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(enabled, isTrue);
    scroll.jumpTo(600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(enabled, isFalse);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(enabled, isTrue);
    // inactive — переход в фон, на котором Flutter ещё рисует кадр.
    // paused выключает framesEnabled у самого тестового binding.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(enabled, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(enabled, isTrue);
    await tester.pumpWidget(const SizedBox());
    final gif = event({
      'msgtype': 'm.image',
      'url': 'mxc://example.invalid/gif',
      'info': {'mimetype': 'image/gif', 'w': 100, 'h': 100, 'size': 512},
    });
    await AppSettings.autoplayImages.setItem(false);
    await tester.pumpWidget(wrap(ImageBubble(gif, width: 100, height: 100)));
    expect(find.byType(ViewportAnimation), findsNothing);
    expect(find.byType(GifBadge), findsOneWidget);
    await AppSettings.autoplayImages.setItem(true);
    await tester.pumpWidget(wrap(ImageBubble(gif, width: 100, height: 100)));
    expect(find.byType(ViewportAnimation), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 61));
  });

  test('все fallback-поверхности сохраняют исходный body', () async {
    // AC:RL-bot-api-interactive-renderers/6
    final e = event({
      'body': '🎲 5',
      'com.liza.dice': {'emoji': '🎲', 'value': 5},
    });
    BotDice.parse(e.content['com.liza.dice']);
    expect(e.body, '🎲 5');
    // Общий SDK-конвертер используется всеми восемью plaintext-поверхностями.
    for (final surface in [
      'chat-list',
      'reply',
      'push',
      'in-app',
      'search',
      'link-preview',
      'forward-preview',
      'notification',
    ]) {
      expect(
        await e.calcLocalizedBody(MatrixLocals(L10nRu()), plaintextBody: true),
        '🎲 5',
        reason: surface,
      );
    }
    for (final data in [
      null,
      true,
      [],
      {'duration': '5'},
      {
        'duration': 5,
        'cover': {'url': 'https://evil/cover'},
      },
    ]) {
      expect(
        BotLivePhoto.parse(event(video(extra: {'com.liza.live_photo': data}))),
        isNull,
      );
    }
  });

  goldenTest(
    'новые bot renderer UI — ledger:RL-bot-api-interactive-renderers',
    fileName: 'bot_interactive_renderers',
    builder: () => Localizations(
      locale: const Locale('ru'),
      delegates: const [
        _SyncL10n(),
        DefaultWidgetsLocalizations.delegate,
        DefaultMaterialLocalizations.delegate,
      ],
      child: GoldenTestGroup(
        columns: 2,
        children: [
          GoldenTestScenario(
            name: 'Контакт',
            child: const BotContactContent(
              contact: BotContact('+79990000000', 'Анна', 'Иванова'),
              color: Colors.black,
            ),
          ),
          GoldenTestScenario(
            name: 'Dice: исход сервера',
            child: const BotDiceContent(
              dice: BotDice('🎲', 5),
              color: Colors.black,
            ),
          ),
          GoldenTestScenario(
            name: 'Круглое видеосообщение',
            child: InlineBotVideo(
              event: event(video()),
              round: true,
              label: 'Видеосообщение',
              poster: const ColoredBox(color: Colors.blueGrey),
            ),
          ),
          GoldenTestScenario(
            name: 'Live photo: обложка и motion',
            child: InlineBotVideo(
              event: event(video()),
              label: 'Живое фото',
              loop: true,
              poster: const ColoredBox(color: Colors.indigo),
            ),
          ),
          GoldenTestScenario(
            name: 'Индикатор черновика',
            child: const MessageTime(
              time: '10:20',
              color: Colors.grey,
              isDraft: true,
            ),
          ),
        ],
      ),
    ),
  );
}
