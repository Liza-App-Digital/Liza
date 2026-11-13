// ledger:RL-telegram-widgets
// guard.render:real-widget
// ignore_for_file: depend_on_referenced_packages
//
// Пузырь виджета на реальном виджете ленты: доверие, «Запустить», бюджет
// живых, размеры, правки состояния, платформенные фолбэки. Движок — фейк.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_api.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_bubble.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_model.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_runtime.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_storage.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../../utils/test_client.dart';
import 'tg_widget_test_support.dart';

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

const _bot = '@shop_bot:example.invalid';
const _otherBot = '@other_bot:example.invalid';

void main() {
  late Client client;
  late Room room;
  late FakeWidgetServer server;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!w:example.invalid', client: client);
    server = FakeWidgetServer(verifiedBots: {_bot});
    resetTgWidgetGlobals(server);
  });

  tearDown(() async {
    tearDownTgWidgetGlobals();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await client.dispose(closeDatabase: true);
  });

  Event widgetEvent(
    String id, {
    String sender = _bot,
    Map<String, Object?>? block,
    String body = 'Счётчик',
    int ts = 1000,
  }) => Event(
    type: EventTypes.Message,
    eventId: id,
    senderId: sender,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    room: room,
    content: widgetContent(
      body: body,
      block: block ?? widgetBlockJson(sender: sender, botId: sender),
    ),
  );

  Widget app(Widget child) => MaterialApp(
    locale: const Locale('ru'),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: Scaffold(body: child),
  );

  Widget bubble(Event e, {Timeline? timeline}) => TgWidgetBubble(
    key: ValueKey(e.eventId),
    event: e,
    timeline: timeline,
    ownMessage: false,
    textColor: Colors.black,
    linkColor: Colors.blue,
  );

  // HTTP фейка (MockClient) и SDK отвечают в реальном event loop — даём им
  // шаг вне FakeAsync, затем докручиваем кадры (видимость → бюджет → движок).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  TgWidgetBubbleState stateOf(WidgetTester tester, String id) =>
      tester.state<TgWidgetBubbleState>(
        find.byKey(ValueKey(id), skipOffstage: false),
      );

  group('доверие', () {
    // AC:RL-telegram-widgets/7
    testWidgets('проверенный бот: живой сразу, без «Запустить»', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(ListView(children: [bubble(widgetEvent(r'$a'))])),
      );
      await settle(tester);
      expect(stateOf(tester, r'$a').phase, TgWidgetPhase.live);
      expect(FakeEngines.live, hasLength(1));
      expect(find.byKey(const ValueKey('tg-widget-start')), findsNothing);
      expect(find.text('Счётчик'), findsOneWidget);
    });

    // AC:RL-telegram-widgets/7
    testWidgets(
      'непроверенный: код не исполняется до «Запустить», тап запускает только это сообщение',
      (tester) async {
        final a = widgetEvent(r'$u1', sender: _otherBot);
        final b = widgetEvent(r'$u2', sender: _otherBot, ts: 2000);
        await tester.pumpWidget(
          app(ListView(children: [bubble(a), bubble(b)])),
        );
        await settle(tester);
        expect(FakeEngines.created, isEmpty);
        expect(find.byKey(const ValueKey('tg-widget-start')), findsNWidgets(2));
        expect(find.text('Запустить'), findsNWidgets(2));
        // Подпись и заявленный размер видны и до запуска.
        expect(find.text('Счётчик'), findsNWidgets(2));

        await tester.tap(find.byKey(const ValueKey('tg-widget-start')).first);
        await settle(tester);
        expect(FakeEngines.live, hasLength(1));
        expect(stateOf(tester, r'$u1').phase, TgWidgetPhase.live);
        expect(stateOf(tester, r'$u2').phase, TgWidgetPhase.awaitingStart);
        // Тап по «Запустить» не доставлен виджету как тап.
        final session = stateOf(tester, r'$u1').session!;
        FakeEngines.live.single.emit({
          't': 'copyText',
          'text': 'leak',
          'tap': 1,
        });
        expect(session.stopped, isFalse);
        expect(find.text('Скопировано в буфер обмена'), findsNothing);
        // У непроверенного нет LizaWidget-фич.
        expect(FakeEngines.live.single.shimConfig['liza'], isEmpty);
      },
    );

    // AC:RL-telegram-widgets/6
    for (final c in <(String, Map<String, Object?>)>[
      ('неподписанный', widgetBlockJson(sign: false)),
      ('подделанный html', widgetBlockJson()..['html'] = '<b>evil</b>'),
      ('неизвестный kid', widgetBlockJson(kid: 'k9')),
    ]) {
      testWidgets('${c.$1} → только подпись, движок не создаётся', (
        tester,
      ) async {
        await tester.pumpWidget(
          app(ListView(children: [bubble(widgetEvent(r'$x', block: c.$2))])),
        );
        await settle(tester);
        expect(stateOf(tester, r'$x').phase, TgWidgetPhase.captionOnly);
        expect(FakeEngines.created, isEmpty);
        expect(find.text('Счётчик'), findsOneWidget);
        expect(find.byKey(const ValueKey('tg-widget-area')), findsNothing);
      });
    }

    testWidgets(
      'копия у другого отправителя — пересланная: isForward, без chatData',
      (tester) async {
        final e = widgetEvent(
          r'$fw',
          sender: '@alice:example.invalid',
          block: widgetBlockJson(),
        );
        // Подписан бот, а отправитель — человек: оригинал невозможен. Бот
        // проверен по bot_id, поэтому копия живая.
        await tester.pumpWidget(app(ListView(children: [bubble(e)])));
        await settle(tester);
        final cfg = FakeEngines.live.single.shimConfig;
        expect(cfg['isForward'], isTrue);
        expect(cfg['chatData'], isNull);
        expect(cfg['chatType'], isNull);
        expect(cfg['queriesAllowed'], isFalse);
      },
    );
  });

  group('размеры', () {
    testWidgets('заглушка до загрузки: 50 при авто, объявленная высота иначе', (
      tester,
    ) async {
      final auto = widgetEvent(r'$h0', sender: _otherBot);
      final fixed = widgetEvent(
        r'$h1',
        sender: _otherBot,
        block: widgetBlockJson(
          sender: _otherBot,
          botId: _otherBot,
          height: 220,
          width: 300,
        ),
      );
      await tester.pumpWidget(
        app(ListView(children: [bubble(auto), bubble(fixed)])),
      );
      await settle(tester);
      final areas = find.byKey(const ValueKey('tg-widget-area'));
      expect(tester.getSize(areas.at(0)).height, 50);
      expect(tester.getSize(areas.at(1)), const Size(300, 220));
    });

    testWidgets('авто-высота 240 → 240; 900 → 600; ширина не меняется', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(ListView(children: [bubble(widgetEvent(r'$s'))])),
      );
      await settle(tester);
      final area = find.byKey(const ValueKey('tg-widget-area'));
      final width = tester.getSize(area).width;
      FakeEngines.live.single.emit({'t': 'size', 'h': 240});
      await settle(tester);
      expect(tester.getSize(area), Size(width, 240));
      FakeEngines.live.single.emit({'t': 'size', 'h': 900});
      await settle(tester);
      expect(tester.getSize(area).height, 600);
      expect(tester.getSize(area).width, width);
    });
  });

  group('бюджет живых', () {
    Future<void> pumpFeed(
      WidgetTester tester,
      int n, {
      bool keepAlive = false,
    }) async {
      await tester.pumpWidget(
        app(
          ListView.builder(
            addAutomaticKeepAlives: keepAlive,
            itemCount: n,
            itemBuilder: (context, i) {
              final child = SizedBox(
                height: 120,
                child: bubble(
                  widgetEvent(
                    '\$w$i',
                    block: widgetBlockJson(height: 60, widgetId: 'w$i'),
                  ),
                ),
              );
              return keepAlive ? _KeepAlive(child: child) : child;
            },
          ),
        ),
      );
      await settle(tester);
    }

    // AC:RL-telegram-widgets/8
    for (final capacity in [2, 3]) {
      for (final n in [1, 20, 100]) {
        testWidgets('≤$capacity живых при N=$n, остальные — постер/заглушка', (
          tester,
        ) async {
          TgWidgetLiveBudget.debugInstance = TgWidgetLiveBudget(
            capacity: capacity,
          );
          await pumpFeed(tester, n);
          final expected = n < capacity ? n : capacity;
          expect(FakeEngines.live, hasLength(expected));
          expect(TgWidgetLiveBudget.instance.liveCount, expected);
          final visible = find.byType(TgWidgetBubble).evaluate().length;
          final idle =
              find
                  .byKey(const ValueKey('tg-widget-placeholder'))
                  .evaluate()
                  .length +
              find.byKey(const ValueKey('tg-widget-poster')).evaluate().length;
          expect(idle, visible - expected);
          // Прокрутка: живые следуют за видимостью, лимит держится.
          await tester.drag(find.byType(ListView), const Offset(0, -700));
          await settle(tester);
          expect(FakeEngines.live.length, lessThanOrEqualTo(capacity));
          expect(
            TgWidgetLiveBudget.instance.liveCount,
            FakeEngines.live.length,
          );
        });
      }
    }

    // AC:RL-telegram-widgets/8
    testWidgets('ушедшие за экран keep-alive строки отпускают WebView', (
      tester,
    ) async {
      await pumpFeed(tester, 30, keepAlive: true);
      final firstLive = List.of(FakeEngines.live);
      expect(firstLive, hasLength(2));
      await tester.drag(find.byType(ListView), const Offset(0, -2400));
      await settle(tester);
      // Строки живы в памяти (keep-alive)…
      expect(
        find.byKey(const ValueKey(r'$w0'), skipOffstage: false),
        findsOneWidget,
      );
      // …а их WebView уничтожены, на экране снова ≤2 живых.
      expect(firstLive.every((h) => h.disposed), isTrue);
      expect(FakeEngines.live.length, lessThanOrEqualTo(2));
      // Постер = снимок последнего кадра.
      await tester.drag(find.byType(ListView), const Offset(0, 2400));
      await settle(tester);
      expect(FakeEngines.live.length, lessThanOrEqualTo(2));
    });

    Future<void> pumpSparse(WidgetTester tester) async {
      // Один виджет и высокая «пустота»: уйти с экрана, не отдавая слот другим.
      await tester.pumpWidget(
        app(
          ListView(
            addAutomaticKeepAlives: true,
            children: [
              _KeepAlive(
                child: SizedBox(
                  height: 120,
                  child: bubble(
                    widgetEvent(r'$park', block: widgetBlockJson(height: 60)),
                  ),
                ),
              ),
              const SizedBox(height: 3000),
            ],
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets(
      'уход с экрана → deactivated без уничтожения; возврат → тот же экземпляр, activated',
      (tester) async {
        await pumpSparse(tester);
        final handle = FakeEngines.live.single;
        await tester.drag(find.byType(ListView), const Offset(0, -1500));
        await settle(tester);
        expect(stateOf(tester, r'$park').slot, TgWidgetSlot.parked);
        expect(handle.disposed, isFalse);
        expect(handle.sent.lastWhere((m) => m['t'] == 'active')['on'], isFalse);
        await tester.drag(find.byType(ListView), const Offset(0, 1500));
        await settle(tester);
        expect(
          FakeEngines.created,
          hasLength(1),
          reason: 'новый WebView не нужен',
        );
        expect(identical(FakeEngines.live.single, handle), isTrue);
        expect(handle.sent.lastWhere((m) => m['t'] == 'active')['on'], isTrue);
      },
    );

    testWidgets('запаркованный уничтожается по таймауту 30 с', (tester) async {
      await pumpSparse(tester);
      final handle = FakeEngines.live.single;
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await settle(tester);
      expect(handle.disposed, isFalse);
      await tester.pump(const Duration(seconds: 31));
      await settle(tester);
      expect(handle.disposed, isTrue);
      expect(FakeEngines.live, isEmpty);
    });

    testWidgets(
      'запаркованный уступает слот видимому (ёмкость не превышается)',
      (tester) async {
        TgWidgetLiveBudget.debugInstance = TgWidgetLiveBudget(capacity: 1);
        await tester.pumpWidget(
          app(
            ListView(
              children: [
                _KeepAlive(
                  child: SizedBox(
                    height: 120,
                    child: bubble(widgetEvent(r'$p1')),
                  ),
                ),
                const SizedBox(height: 1500),
                _KeepAlive(
                  child: SizedBox(
                    height: 120,
                    child: bubble(widgetEvent(r'$p2')),
                  ),
                ),
                const SizedBox(height: 3000),
              ],
            ),
          ),
        );
        await settle(tester);
        final first = FakeEngines.live.single;
        await tester.drag(find.byType(ListView), const Offset(0, -1500));
        await settle(tester);
        expect(first.disposed, isTrue);
        expect(FakeEngines.live, hasLength(1));
        expect(stateOf(tester, r'$p2').slot, TgWidgetSlot.active);
      },
    );

    testWidgets(
      'перенос элемента (deactivate) гасит экземпляр, слот не теряется',
      (tester) async {
        final key = GlobalKey();
        Widget tree(bool left) => app(
          Row(
            children: [
              Expanded(
                child: left
                    ? KeyedSubtree(key: key, child: bubble(widgetEvent(r'$mv')))
                    : const SizedBox(),
              ),
              Expanded(
                child: left
                    ? const SizedBox()
                    : KeyedSubtree(
                        key: key,
                        child: bubble(widgetEvent(r'$mv')),
                      ),
              ),
            ],
          ),
        );
        await tester.pumpWidget(tree(true));
        await settle(tester);
        final first = FakeEngines.live.single;
        await tester.pumpWidget(tree(false));
        await settle(tester);
        expect(first.disposed, isTrue);
        expect(FakeEngines.live, hasLength(1));
        expect(TgWidgetLiveBudget.instance.liveCount, 1);
      },
    );
  });

  group('сторож и повтор', () {
    testWidgets(
      '«Widget stopped»: одна повторная попытка при следующем показе, потом стоп',
      (tester) async {
        await tester.pumpWidget(
          app(
            ListView(
              children: [
                SizedBox(height: 120, child: bubble(widgetEvent(r'$st'))),
                const SizedBox(height: 3000),
              ],
            ),
          ),
        );
        await settle(tester);
        FakeEngines.live.single.emit({'t': 'dom', 'n': 5000});
        await settle(tester);
        expect(stateOf(tester, r'$st').phase, TgWidgetPhase.stopped);
        expect(find.text('Виджет остановлен'), findsOneWidget);
        Future<void> awayAndBack() async {
          await tester.drag(find.byType(ListView), const Offset(0, -1500));
          await settle(tester);
          await tester.drag(find.byType(ListView), const Offset(0, 1500));
          await settle(tester);
        }

        await awayAndBack();
        expect(stateOf(tester, r'$st').phase, TgWidgetPhase.live);
        expect(FakeEngines.created, hasLength(2));
        FakeEngines.live.single.emit({'t': 'dom', 'n': 5000});
        await settle(tester);
        await awayAndBack();
        expect(stateOf(tester, r'$st').phase, TgWidgetPhase.stopped);
        expect(FakeEngines.created, hasLength(2));
      },
    );
  });

  group('лента и правки', () {
    Event edit(Event original, String chatData, {String? sender}) => Event(
      type: EventTypes.Message,
      eventId: '${original.eventId}-edit-$chatData',
      senderId: sender ?? original.senderId,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(5000),
      room: room,
      content: {
        'msgtype': 'm.text',
        'body': '* Счётчик',
        TgWidgetBlock.silentKey: true,
        'm.new_content': {
          'msgtype': 'm.text',
          'body': 'Счётчик',
          TgWidgetBlock.silentKey: true,
          TgWidgetBlock.contentKey: widgetBlockJson(
            chatData: chatData,
            html: '<script>evil()</script>',
          ),
        },
        'm.relates_to': {
          'rel_type': RelationshipTypes.edit,
          'event_id': original.eventId,
        },
      },
    );

    Future<void> pumpMessage(WidgetTester tester, Event e, Timeline t) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ru'),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: Provider<liza_matrix.MatrixState>.value(
              value: _TestMatrixState(client),
              child: Scaffold(
                body: ListView(
                  controller: scroll,
                  children: [
                    Message(
                      e,
                      timeline: t,
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
            ),
          ),
        ),
      );
      await settle(tester);
    }

    // AC:RL-telegram-widgets/3
    testWidgets(
      'chat_data из m.replace виден, метки «изменено» нет, код — из оригинала',
      (tester) async {
        final original = widgetEvent(r'$orig');
        final t = Timeline(
          room: room,
          chunk: TimelineChunk(events: [edit(original, '{"n":7}'), original]),
        );
        addTearDown(t.cancelSubscriptions);
        await pumpMessage(tester, original, t);
        await settle(tester);
        expect(find.byType(TgWidgetBubble), findsOneWidget);
        expect(find.byIcon(Icons.edit_outlined), findsNothing);
        final handle = FakeEngines.live.single;
        expect(handle.shimConfig['chatData'], '{"n":7}');
        expect(handle.config.document, contains('<div id="w">hi</div>'));
        expect(handle.config.document, isNot(contains('evil()')));
      },
    );

    test('правка чужим отправителем состояние не меняет', () {
      final original = widgetEvent(r'$o2');
      final t = Timeline(
        room: room,
        chunk: TimelineChunk(
          events: [
            edit(original, '{"n":99}', sender: '@mallory:example.invalid'),
            original,
          ],
        ),
      );
      addTearDown(t.cancelSubscriptions);
      expect(resolveTgWidgetState(original, t)!.chatData, '{"n":0}');
    });

    testWidgets('без подписи (has_caption=false): время поверх, подписи нет', (
      tester,
    ) async {
      final e = widgetEvent(
        r'$nc',
        body: 'Виджет',
        block: widgetBlockJson(hasCaption: false),
      );
      final t = Timeline(
        room: room,
        chunk: TimelineChunk(events: [e]),
      );
      addTearDown(t.cancelSubscriptions);
      await pumpMessage(tester, e, t);
      await settle(tester);
      expect(find.text('Виджет'), findsNothing);
      // Время лежит поверх низа виджета → нижний inset > 0 и угол справа.
      final handle = FakeEngines.live.single;
      handle.emit({'t': 'loaded'});
      await settle(tester);
      final sentInset = handle.sent.where((m) => m['t'] == 'inset');
      final inset = sentInset.isEmpty
          ? handle.shimConfig['inset'] as Map
          : sentInset.last['inset'] as Map;
      expect(inset['bottom'], greaterThan(0));
      expect(inset['cornerRight'], greaterThan(0));
      expect(
        (handle.shimConfig['css']
            as Map)['--tg-content-safe-area-inset-bottom'],
        isNot('0px'),
      );
    });

    testWidgets('превью для списка чатов/пушей/ответов = подпись (body)', (
      tester,
    ) async {
      final e = widgetEvent(r'$p', body: 'Корзина: 3 товара');
      final l10n = (await tester.runAsync(
        () => L10n.delegate.load(const Locale('ru')),
      ))!;
      expect(
        e.calcLocalizedBodyFallback(MatrixLocals(l10n)),
        'Корзина: 3 товара',
      );
    });
  });

  group('платформы и защита', () {
    testWidgets(
      'Web: непроверенный бот — подпись и «откройте в приложении», без «Запустить» и движка',
      (tester) async {
        TgWidgetEngines.debugLiveOnlyForVerified = true;
        await tester.pumpWidget(
          app(
            ListView(
              children: [bubble(widgetEvent(r'$web', sender: _otherBot))],
            ),
          ),
        );
        await settle(tester);
        expect(stateOf(tester, r'$web').phase, TgWidgetPhase.appOnly);
        expect(find.text('Откройте виджет в приложении Liza'), findsOneWidget);
        expect(find.byKey(const ValueKey('tg-widget-start')), findsNothing);
        expect(FakeEngines.created, isEmpty);
      },
    );

    testWidgets('Web: проверенный бот — живой', (tester) async {
      TgWidgetEngines.debugLiveOnlyForVerified = true;
      await tester.pumpWidget(
        app(ListView(children: [bubble(widgetEvent(r'$web2'))])),
      );
      await settle(tester);
      expect(FakeEngines.live, hasLength(1));
    });

    // AC:RL-telegram-widgets/4
    testWidgets(
      'viewer от /liza/v1/widget-viewer попадает в TelegramWidget.viewer',
      (tester) async {
        await tester.pumpWidget(
          app(ListView(children: [bubble(widgetEvent(r'$v'))])),
        );
        await settle(tester);
        expect(FakeEngines.live.single.shimConfig['viewer'], {
          'id': 4242,
          'first_name': 'Алиса',
          'username': 'alice',
        });
        final body =
            jsonDecode(
                  server.requests
                      .lastWhere((r) => r.url.path == '/liza/v1/widget-viewer')
                      .body,
                )
                as Map;
        expect(body['room_id'], '!w:example.invalid');
        expect(body['event_id'], r'$v');
        expect(body['widget_id'], '101');
      },
    );

    testWidgets('ошибка widget-viewer → viewer null, виджет всё равно живой', (
      tester,
    ) async {
      server.viewerStatus = 500;
      await tester.pumpWidget(
        app(ListView(children: [bubble(widgetEvent(r'$v2'))])),
      );
      await settle(tester);
      expect(FakeEngines.live.single.shimConfig['viewer'], isNull);
    });

    testWidgets('allow_queries=false → viewer не запрашивается', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          ListView(
            children: [
              bubble(
                widgetEvent(
                  r'$v3',
                  block: widgetBlockJson(allowQueries: false),
                ),
              ),
            ],
          ),
        ),
      );
      await settle(tester);
      expect(server.count('/liza/v1/widget-viewer'), 0);
      expect(FakeEngines.live.single.shimConfig['viewer'], isNull);
    });

    testWidgets('«Запустить» запоминается на сообщение постоянно', (
      tester,
    ) async {
      final e = widgetEvent(r'$rem', sender: _otherBot);
      await tester.pumpWidget(app(ListView(children: [bubble(e)])));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('tg-widget-start')));
      await settle(tester);
      expect(
        await tester.runAsync(() => TgWidgetStorage.wasStarted(r'$rem')),
        isTrue,
      );
      await tester.pumpWidget(app(const SizedBox()));
      await settle(tester);
      await tester.pumpWidget(app(ListView(children: [bubble(e)])));
      await settle(tester);
      expect(find.byKey(const ValueKey('tg-widget-start')), findsNothing);
      expect(stateOf(tester, r'$rem').phase, TgWidgetPhase.live);
    });

    testWidgets('copyText: тост показывает скопированный текст', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(ListView(children: [bubble(widgetEvent(r'$cp'))])),
      );
      await settle(tester);
      final handle = FakeEngines.live.single;
      handle.hostTap();
      handle.emit({'t': 'copyText', 'text': 'PROMO-2026', 'tap': 1});
      await settle(tester);
      expect(find.text('Скопировано: PROMO-2026'), findsOneWidget);
    });

    testWidgets(
      'инлайн-превью: isPreview, тапы виджету не идут, запросы NOT_ALLOWED',
      (tester) async {
        var selected = 0;
        final e = widgetEvent(r'$prev');
        await tester.pumpWidget(
          app(
            ListView(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => selected++,
                  child: TgWidgetBubble(
                    key: ValueKey(e.eventId),
                    event: e,
                    timeline: null,
                    ownMessage: false,
                    textColor: Colors.black,
                    linkColor: Colors.blue,
                    isPreview: true,
                  ),
                ),
              ],
            ),
          ),
        );
        await settle(tester);
        final handle = FakeEngines.live.single;
        expect(handle.shimConfig['isPreview'], isTrue);
        expect(handle.shimConfig['queriesAllowed'], isFalse);
        expect(handle.shimConfig['chatType'], isNull);
        expect(find.byKey(const ValueKey('tg-widget-preview')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tg-widget-area')));
        await settle(tester);
        expect(selected, 1, reason: 'тап выбрал результат');
        handle.emit({'t': 'openLink', 'url': 'https://example.com', 'tap': 1});
        handle.emit({'t': 'request', 'id': 1, 'data': 'x', 'tap': 1});
        await settle(tester);
        expect(
          handle.sent.lastWhere((m) => m['t'] == 'result')['code'],
          'NOT_ALLOWED',
        );
      },
    );

    testWidgets('Linux: подпись + «не поддерживается», движка нет', (
      tester,
    ) async {
      TgWidgetEngines.debugSupported = false;
      await tester.pumpWidget(
        app(ListView(children: [bubble(widgetEvent(r'$l'))])),
      );
      await settle(tester);
      expect(stateOf(tester, r'$l').phase, TgWidgetPhase.unsupported);
      expect(find.text('Счётчик'), findsOneWidget);
      expect(
        find.text('Виджеты не поддерживаются на этом устройстве'),
        findsOneWidget,
      );
      expect(FakeEngines.created, isEmpty);
    });

    test('forwarding выключен (или неизвестен) → виджет защищён', () async {
      final e = widgetEvent(r'$prot');
      expect(isProtectedTgWidget(e), isTrue, reason: 'scopes ещё не загружены');
      await TgWidgetApi.forBase(tgWidgetApiBase(client)).scopes();
      expect(isProtectedTgWidget(e), isTrue);
      final text = Event(
        type: EventTypes.Message,
        eventId: r'$t',
        senderId: _bot,
        originServerTs: DateTime(2026),
        room: room,
        content: {'msgtype': 'm.text', 'body': 'hi'},
      );
      expect(isProtectedTgWidget(text), isFalse);
    });

    test('forwarding включён → пересылать можно', () async {
      server.scopes = {'private', 'forwarding'};
      await TgWidgetApi.forBase(tgWidgetApiBase(client)).scopes();
      expect(isProtectedTgWidget(widgetEvent(r'$fw2')), isFalse);
    });

    test(
      'protect_content=true → защищён даже при forwarding (и копия тоже)',
      () async {
        server.scopes = {'private', 'forwarding'};
        await TgWidgetApi.forBase(tgWidgetApiBase(client)).scopes();
        final block = widgetBlockJson(protectContent: true);
        expect(isProtectedTgWidget(widgetEvent(r'$pc', block: block)), isTrue);
        final copy = widgetEvent(
          r'$pc2',
          sender: '@alice:example.invalid',
          block: block,
        );
        expect(isProtectedTgWidget(copy), isTrue);
      },
    );
  });

  group('общие виджеты', () {
    test('5 наблюдателей одного widget_id → один опрос на cache_time', () {
      fakeAsync((async) {
        server.sharedData['sh'] = 'v1';
        server.sharedCacheTime = 10;
        final api = server.api('https://bot.example.invalid');
        final got = <String?>[];
        final cancels = [
          for (var i = 0; i < 5; i++)
            TgSharedWidgetPoller.instance.watch(api, 'sh', got.add),
        ];
        async.flushMicrotasks();
        expect(server.count('/liza/v1/widgets/sh'), 1);
        expect(got, List.filled(5, 'v1'));
        server.sharedData['sh'] = 'v2';
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(server.count('/liza/v1/widgets/sh'), 2);
        expect(got.where((v) => v == 'v2'), hasLength(5));
        // Без изменений сервер отвечает 304 — слушатели не дёргаются.
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(server.count('/liza/v1/widgets/sh'), 3);
        expect(got, hasLength(10));
        for (final c in cancels) {
          c();
        }
        expect(TgSharedWidgetPoller.instance.activePolls, 0);
        async.elapse(const Duration(seconds: 30));
        expect(server.count('/liza/v1/widgets/sh'), 3);
      });
    });
  });
}

class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
