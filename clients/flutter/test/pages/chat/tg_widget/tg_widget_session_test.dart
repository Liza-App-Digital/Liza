// ledger:RL-telegram-widgets
//
// Хост-сторона моста TelegramWidget. Мост недоверенный: тап, квоту, запросы и
// mxc проверяет хост. Движок — фейковый канал, логика — настоящая.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_api.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_model.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_session.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_storage.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_tap.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_theme.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_trust.dart';

import 'tg_widget_test_support.dart';

class _Handle implements TgWidgetEngineHandle {
  final List<Map<String, Object?>> sent = [];

  @override
  Future<void> send(String json) async =>
      sent.add(jsonDecode(json) as Map<String, Object?>);

  @override
  Future<Uint8List?> snapshot() async => null;
}

class _Delegate implements TgWidgetSessionDelegate {
  final List<Uri> links = [];
  final List<String> botChats = [];
  final List<String> copied = [];
  final List<String> haptics = [];
  final List<TgWidgetStopReason> stops = [];
  final List<double> sizes = [];
  String? anchor;
  bool? watching;
  ({Uint8List bytes, String mime})? media;

  @override
  void onWidgetSize(double h) => sizes.add(h);
  @override
  void onWidgetReady() {}
  @override
  void onWidgetStopped(TgWidgetStopReason reason) => stops.add(reason);
  @override
  void onResizeAnchor(String edge) => anchor = edge;
  @override
  void onWatchPublicData(bool on) => watching = on;
  @override
  void openLink(Uri url) => links.add(url);
  @override
  void openBotChat(String botMxid) => botChats.add(botMxid);
  @override
  void copyText(String text) => copied.add(text);
  @override
  void haptic(String kind, String? style) => haptics.add('$kind:$style');
  @override
  Future<({Uint8List bytes, String mime})?> resolveMxc(Uri mxc) async => media;
}

final _light = TgWidgetTheme.of(
  ThemeData(brightness: Brightness.light),
  outgoing: false,
  fontSize: 15,
);
final _dark = TgWidgetTheme.of(
  ThemeData(brightness: Brightness.dark),
  outgoing: false,
  fontSize: 15,
);

void main() {
  late FakeWidgetServer server;
  late _Delegate delegate;
  late _Handle handle;
  var clock = DateTime(2026, 11, 13, 12);

  TgWidgetSession make({
    TgWidgetTrustKind trust = TgWidgetTrustKind.original,
    String? chatType = 'private',
    bool isPreview = false,
    bool verified = true,
    Map<String, Object?>? block,
    Map<String, Object?>? viewer,
    Map<String, String> local = const {},
  }) {
    handle = _Handle();
    final s = TgWidgetSession(
      ctx: TgWidgetSessionContext(
        block: TgWidgetBlock.tryParse(block ?? widgetBlockJson())!,
        trust: trust,
        chatType: chatType,
        isPreview: isPreview,
        verifiedBot: verified,
        roomId: '!w:example.invalid',
        eventId: r'$widget',
        storageKey: 'me|!w:example.invalid|\$widget',
        viewer: viewer,
        mxcServers: const {'example.invalid'},
      ),
      delegate: delegate,
      api: server.api('https://bot.example.invalid'),
      openId: () async => TgWidgetOpenId(
        accessToken: 'oid-token',
        matrixServerName: 'example.invalid',
        expiresAt: clock.add(const Duration(hours: 1)),
      ),
      theme: _light,
      inset: const TgWidgetInset(),
      active: true,
      localStorage: local,
      tapGate: TgWidgetTapGate(now: () => clock),
      now: () => clock,
    );
    s.attach(handle);
    return s;
  }

  void emit(TgWidgetSession s, Map<String, Object?> msg) =>
      s.handleRaw(jsonEncode({...msg, 's': s.secret}));

  void tap(TgWidgetSession s) => hostTapTo(s.onPointer);

  Future<Map<String, Object?>> request(
    TgWidgetSession s, {
    String data = 'inc',
    bool hostTap = true,
    int id = 7,
  }) async {
    if (hostTap) tap(s);
    // Номер тапа от шима (`tap`) хост не учитывает вовсе — шлём «подделку».
    emit(s, {'t': 'request', 'id': id, 'data': data, 'tap': 999});
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
      final r = handle.sent.where((m) => m['t'] == 'result' && m['id'] == id);
      if (r.isNotEmpty) return r.last;
    }
    fail('no result');
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = FakeWidgetServer();
    delegate = _Delegate();
    clock = DateTime(2026, 11, 13, 12);
    TgWidgetStorage.debugClear();
  });

  group('конфиг шима (поля TelegramWidget)', () {
    // AC:RL-telegram-widgets/4
    test('оригинал в личке: chatType, chatData, viewer, isForward=false', () {
      final cfg = make(
        viewer: {'id': 7, 'first_name': 'Аня'},
      ).buildConfig(transport: 'native');
      expect(cfg['chatType'], 'private');
      expect(cfg['chatData'], '{"n":0}');
      expect(cfg['isForward'], isFalse);
      expect(cfg['isPreview'], isFalse);
      expect(cfg['colorScheme'], 'light');
      expect(cfg['viewer'], {'id': 7, 'first_name': 'Аня'});
      expect((cfg['themeParams'] as Map)['bg_color'], startsWith('#'));
      expect(cfg['queriesAllowed'], isTrue);
      expect(cfg['backgroundAllowed'], isTrue);
    });

    // AC:RL-telegram-widgets/4
    test(
      'viewer — null там, где запросы запрещены (static forward, allow_queries=false, превью)',
      () {
        const v = {'id': 7};
        expect(
          make(
            trust: TgWidgetTrustKind.forwarded,
            viewer: v,
          ).buildConfig(transport: 'native')['viewer'],
          isNull,
        );
        expect(
          make(
            block: widgetBlockJson(allowQueries: false),
            viewer: v,
          ).buildConfig(transport: 'native')['viewer'],
          isNull,
        );
        expect(
          make(
            isPreview: true,
            viewer: v,
          ).buildConfig(transport: 'native')['viewer'],
          isNull,
        );
      },
    );

    test('пересланная копия: isForward, chatData и chatType — null', () {
      final cfg = make(
        trust: TgWidgetTrustKind.forwarded,
      ).buildConfig(transport: 'native');
      expect(cfg['isForward'], isTrue);
      expect(cfg['chatData'], isNull);
      expect(cfg['chatType'], isNull);
      expect(cfg['queriesAllowed'], isFalse);
    });

    // AC:RL-telegram-widgets/10
    test('LizaWidget-фичи только у проверенного бота', () {
      expect(make(verified: true).buildConfig(transport: 'native')['liza'], [
        'mxc',
      ]);
      expect(
        make(verified: false).buildConfig(transport: 'native')['liza'],
        isEmpty,
      );
    });

    test(
      'тема: все ключи ThemeParams и --tg-* переменные; color-scheme meta',
      () {
        expect(_light.themeParams.keys, {
          'bg_color',
          'text_color',
          'hint_color',
          'link_color',
          'button_color',
          'button_text_color',
          'secondary_bg_color',
          'accent_text_color',
          'subtitle_text_color',
          'destructive_text_color',
          'section_bg_color',
          'section_header_text_color',
          'section_separator_color',
          'header_bg_color',
          'bottom_bar_bg_color',
        });
        final css = _light.cssVars;
        expect(css['--tg-theme-bg-color'], _light.themeParams['bg_color']);
        expect(css['--tg-color-scheme'], 'light');
        expect(css['--tg-text-font-size'], '15px');
        expect(
          make().buildDocument(transport: 'native'),
          contains('<meta name="color-scheme" content="light">'),
        );
      },
    );

    test('сообщения с чужим секретом игнорируются', () {
      final s = make();
      s.handleRaw(jsonEncode({'t': 'size', 'h': 300, 's': 'wrong'}));
      s.handleRaw('not json');
      expect(delegate.sizes, isEmpty);
      emit(s, {'t': 'size', 'h': 300});
      expect(delegate.sizes, [300]);
    });
  });

  group('гейт тапа — только хост', () {
    test('скролл по виджету ≠ тап', () {
      final s = make(chatType: 'group');
      hostSwipeTo(s.onPointer);
      emit(s, {'t': 'copyText', 'text': 'x', 'tap': 1});
      expect(delegate.copied, isEmpty);
    });

    test('касание во время прокрутки ленты ≠ тап (и конец свайпа тоже)', () {
      final s = make();
      s.setFeedScrolling(true);
      tap(s);
      s.setFeedScrolling(false);
      emit(s, {'t': 'copyText', 'text': 'x', 'tap': 1});
      expect(delegate.copied, isEmpty);
    });

    test('долгое удержание (> 500 мс) ≠ тап', () {
      final gate = TgWidgetTapGate(now: () => clock);
      gate.onPointer(const PointerDownEvent(pointer: 1));
      clock = clock.add(const Duration(milliseconds: 700));
      gate.onPointer(const PointerUpEvent(pointer: 1));
      expect(gate.consume(), isFalse);
    });

    test('два действия на один тап → второе не проходит', () async {
      final s = make(chatType: 'group');
      tap(s);
      emit(s, {'t': 'openLink', 'url': 'https://example.com/a', 'tap': 1});
      emit(s, {'t': 'copyText', 'text': 'x', 'tap': 1});
      expect(delegate.links, hasLength(1));
      expect(delegate.copied, isEmpty);
      expect((await request(s, hostTap: false))['code'], 'NOT_ALLOWED');
    });

    test(
      'JS-«тап» без касания хоста (прямой вызов моста) → NOT_ALLOWED',
      () async {
        final s = make(chatType: 'group');
        emit(s, {'t': 'openLink', 'url': 'https://example.com', 'tap': 1});
        expect(delegate.links, isEmpty);
        expect((await request(s, hostTap: false))['code'], 'NOT_ALLOWED');
        expect(server.count('/liza/v1/widget-query'), 0);
      },
    );

    test('тап протухает через 1,5 с', () {
      final s = make();
      tap(s);
      clock = clock.add(const Duration(milliseconds: 1600));
      emit(s, {'t': 'copyText', 'text': 'x', 'tap': 1});
      expect(delegate.copied, isEmpty);
    });

    test('Web: тап = сигнал активации iframe от хоста', () {
      final s = make();
      s.onActivation();
      emit(s, {'t': 'copyText', 'text': 'web', 'tap': 1});
      emit(s, {'t': 'copyText', 'text': 'again', 'tap': 1});
      expect(delegate.copied, ['web']);
    });
  });

  group('request', () {
    test('тап → POST /liza/v1/widget-query и { result }', () async {
      server.onQuery = (_) => {'ok': true, 'result': '{"n":1}'};
      final s = make();
      final r = await request(s);
      expect(r['ok'], isTrue);
      expect(r['result'], '{"n":1}');
      final body =
          jsonDecode(
                server.requests
                    .lastWhere((q) => q.url.path == '/liza/v1/widget-query')
                    .body,
              )
              as Map;
      expect(body['openid'], {
        'access_token': 'oid-token',
        'matrix_server_name': 'example.invalid',
      });
      expect(body['room_id'], '!w:example.invalid');
      expect(body['event_id'], r'$widget');
      expect(body['widget_id'], '101');
      expect(body['data'], 'inc');
      expect(body['background'], isFalse);
      expect(body['instance_id'], s.instanceId);
    });

    test(
      'коды ошибок сервера → WidgetRequestError, неизвестный → FAILED',
      () async {
        for (final code in [
          'BUSY',
          'RATE_LIMITED',
          'TIMEOUT',
          'NOT_ALLOWED',
          'INVALID_ANSWER',
        ]) {
          server.onQuery = (_) => {'ok': false, 'code': code};
          expect((await request(make()))['code'], code);
        }
        server.onQuery = (_) => {'ok': false, 'code': 'WHATEVER'};
        expect((await request(make()))['code'], 'FAILED');
      },
    );

    test('группа: без тапа → NOT_ALLOWED (фон только в личке)', () async {
      final s = make(chatType: 'group');
      expect((await request(s, hostTap: false))['code'], 'NOT_ALLOWED');
    });

    test('личка: фон разрешён, но не чаще раза в 5 с', () async {
      final s = make();
      expect((await request(s, hostTap: false, id: 1))['ok'], isTrue);
      final body = jsonDecode(server.requests.last.body) as Map;
      expect(body['background'], isTrue);
      expect((await request(s, hostTap: false, id: 2))['code'], 'RATE_LIMITED');
      clock = clock.add(const Duration(seconds: 6));
      expect((await request(s, hostTap: false, id: 3))['ok'], isTrue);
    });

    test('пересланный статический виджет и превью → NOT_ALLOWED', () async {
      expect(
        (await request(make(trust: TgWidgetTrustKind.forwarded)))['code'],
        'NOT_ALLOWED',
      );
      expect((await request(make(isPreview: true)))['code'], 'NOT_ALLOWED');
      expect(server.count('/liza/v1/widget-query'), 0);
    });

    test(
      'пересланный общий виджет с allow_queries → запрос без room/event',
      () async {
        final s = make(
          trust: TgWidgetTrustKind.forwarded,
          block: widgetBlockJson(isShared: true, widgetId: 'sh1'),
        );
        expect((await request(s))['ok'], isTrue);
        final body = jsonDecode(server.requests.last.body) as Map;
        expect(body.containsKey('room_id'), isFalse);
        expect(body.containsKey('event_id'), isFalse);
        expect(body['widget_id'], 'sh1');
      },
    );

    test('allow_queries=false → NOT_ALLOWED', () async {
      final s = make(block: widgetBlockJson(allowQueries: false));
      expect((await request(s))['code'], 'NOT_ALLOWED');
    });

    test('второй запрос, пока первый в полёте → BUSY', () async {
      final gate = Completer<Map<String, Object?>>();
      server.onQuery = (_) => gate.future;
      final s = make();
      tap(s);
      emit(s, {'t': 'request', 'id': 1, 'data': 'a', 'tap': 1});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      tap(s);
      emit(s, {'t': 'request', 'id': 2, 'data': 'b', 'tap': 2});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(handle.sent.firstWhere((m) => m['id'] == 2)['code'], 'BUSY');
      gate.complete({'ok': true, 'result': 'x'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(handle.sent.firstWhere((m) => m['id'] == 1)['ok'], isTrue);
    });

    test('данные вне 1–64 байт отклоняются хостом', () async {
      expect((await request(make(), data: 'я' * 33))['code'], 'BAD_REQUEST');
    });
  });

  group('действия', () {
    test('openLink: только https, ≤256, не t.me, без user:pass@', () {
      final s = make();
      for (final url in [
        'http://example.com',
        'javascript:alert(1)',
        'https://t.me/x',
        'https://user:pass@example.com/',
        'https://user@example.com/',
        'https://example.com/${'a' * 260}',
      ]) {
        tap(s);
        emit(s, {'t': 'openLink', 'url': url, 'tap': 1});
      }
      expect(delegate.links, isEmpty);
      tap(s);
      emit(s, {'t': 'openLink', 'url': 'https://example.com/ok', 'tap': 1});
      expect(delegate.links, [Uri.parse('https://example.com/ok')]);
    });

    test(
      'openTelegramLink: свой бот → чат бота, чужой — ничего (тап не тратится)',
      () {
        final s = make();
        tap(s);
        emit(s, {
          't': 'openTelegramLink',
          'url': 'https://t.me/other_bot',
          'tap': 1,
        });
        emit(s, {
          't': 'openTelegramLink',
          'url': 'https://t.me/Shop_Bot',
          'tap': 1,
        });
        expect(delegate.botChats, ['@shop_bot:example.invalid']);
      },
    );

    test('превью: ссылки/копирование/вибро — no-op даже после касания', () {
      final s = make(isPreview: true);
      tap(s);
      emit(s, {'t': 'openLink', 'url': 'https://example.com', 'tap': 1});
      emit(s, {'t': 'copyText', 'text': 'x', 'tap': 1});
      emit(s, {'t': 'haptic', 'kind': 'impact', 'style': 'light'});
      expect(delegate.links, isEmpty);
      expect(delegate.copied, isEmpty);
      expect(delegate.haptics, isEmpty);
    });

    test('вибро: только видимым, в 5 с после касания и ≤20 в секунду', () {
      final s = make();
      emit(s, {'t': 'haptic', 'kind': 'impact', 'style': 'light'});
      expect(delegate.haptics, isEmpty);
      tap(s);
      for (var i = 0; i < 30; i++) {
        emit(s, {'t': 'haptic', 'kind': 'selection'});
      }
      expect(delegate.haptics, hasLength(TgWidgetSession.hapticsPerSecond));
      clock = clock.add(const Duration(seconds: 6));
      emit(s, {'t': 'haptic', 'kind': 'selection'});
      expect(delegate.haptics, hasLength(TgWidgetSession.hapticsPerSecond));
    });
  });

  group('тема, видимость, состояние', () {
    test('переключение темы → themeChanged с colorScheme dark', () async {
      final s = make();
      await s.setTheme(_dark);
      final m = handle.sent.last;
      expect(m['t'], 'theme');
      expect(m['colorScheme'], 'dark');
      expect((m['css'] as Map)['--tg-color-scheme'], 'dark');
      await s.setTheme(_dark);
      expect(handle.sent.where((m) => m['t'] == 'theme').length, 1);
    });

    test('видимость: deactivated/activated', () async {
      final s = make();
      await s.setActive(false);
      await s.setActive(true);
      expect(handle.sent.where((m) => m['t'] == 'active').map((m) => m['on']), [
        false,
        true,
      ]);
    });

    // AC:RL-telegram-widgets/3
    test(
      'правка состояния ботом → state (chatData в пересланной — null)',
      () async {
        final s = make();
        await s.setState(chatData: '{"n":5}', publicData: 'p');
        expect(handle.sent.last, containsPair('chatData', '{"n":5}'));
        final f = make(trust: TgWidgetTrustKind.forwarded);
        await f.setState(chatData: '{"n":5}', publicData: 'p');
        expect(handle.sent.last['chatData'], isNull);
        expect(handle.sent.last['publicData'], 'p');
      },
    );

    test('safe area → inset + contentSafeAreaChanged', () async {
      final s = make();
      await s.setInset(const TgWidgetInset(bottom: 22, cornerRight: 60));
      final m = handle.sent.last;
      expect(m['t'], 'inset');
      expect((m['inset'] as Map)['bottom'], 22);
      expect((m['inset'] as Map)['cornerRight'], 60);
    });

    test('setResizeAnchor и watchPublicData доходят до хоста', () {
      final s = make(block: widgetBlockJson(isShared: true));
      emit(s, {'t': 'anchor', 'edge': 'bottom'});
      emit(s, {'t': 'anchor', 'edge': 'left'});
      emit(s, {'t': 'watch', 'on': true});
      expect(delegate.anchor, 'bottom');
      expect(delegate.watching, isTrue);
    });
  });

  group('Web Storage (квоту проверяет хост)', () {
    test('localStorage сохраняется постоянно по сообщению', () async {
      final s = make();
      emit(s, {
        't': 'storage',
        'area': 'local',
        'data': {'best': '42'},
      });
      await Future<void>.delayed(Duration.zero);
      TgWidgetStorage.debugClear();
      expect(
        await TgWidgetStorage.loadLocal('me|!w:example.invalid|\$widget'),
        {'best': '42'},
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().any((k) => k.startsWith('tgw.ls.')), isTrue);
    });

    test('сверх 4 КБ (UTF-8 ключи+значения) — хост не сохраняет', () async {
      final s = make(local: {'a': '1'});
      emit(s, {
        't': 'storage',
        'area': 'local',
        'data': {'big': 'я' * 2100},
      });
      await Future<void>.delayed(Duration.zero);
      expect(s.localStorage, {'a': '1'});
      TgWidgetStorage.debugClear();
      expect(
        await TgWidgetStorage.loadLocal('me|!w:example.invalid|\$widget'),
        isEmpty,
      );
    });

    test('превью: хранилище пустое и ничего не сохраняется', () async {
      final s = make(isPreview: true, local: {'k': 'v'});
      expect(
        (s.buildConfig(transport: 'native')['storage'] as Map)['local'],
        isEmpty,
      );
      emit(s, {
        't': 'storage',
        'area': 'local',
        'data': {'k': 'v2'},
      });
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.startsWith('tgw.ls.')), isEmpty);
    });

    test('sessionStorage — до перезапуска, своё у сообщения', () async {
      final s = make();
      emit(s, {
        't': 'storage',
        'area': 'session',
        'data': {'s': '1'},
      });
      await Future<void>.delayed(Duration.zero);
      final again = make().buildConfig(transport: 'native');
      expect((again['storage'] as Map)['session'], {'s': '1'});
    });
  });

  group('сторож', () {
    test('шим молчит > 1 с на регулярных тиках → остановлен', () {
      fakeAsync((async) {
        final start = DateTime(2026, 11, 13);
        clock = start;
        final s = make();
        emit(s, {'t': 'loaded'});
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(milliseconds: 200));
          clock = start.add(async.elapsed);
          emit(s, {'t': 'hb', 'n': 10, 'gap': 200});
        }
        expect(delegate.stops, isEmpty);
        // while(true){}: heartbeat встал.
        for (var i = 0; i < 6; i++) {
          async.elapse(const Duration(milliseconds: 250));
          clock = start.add(async.elapsed);
        }
        expect(delegate.stops, [TgWidgetStopReason.watchdog]);
        s.dispose();
      });
    });

    test('подвис UI-поток Flutter (таймер опоздал) — виджет жив', () {
      fakeAsync((async) {
        final start = DateTime(2026, 11, 13);
        clock = start;
        final s = make();
        emit(s, {'t': 'loaded'});
        // Dart-таймер не тикал 3 с (стоп UI-потока), часы ушли вперёд.
        clock = start.add(const Duration(seconds: 3));
        async.elapse(const Duration(milliseconds: 250));
        clock = start.add(const Duration(seconds: 3, milliseconds: 250));
        emit(s, {'t': 'hb', 'n': 10, 'gap': 200});
        async.elapse(const Duration(milliseconds: 250));
        expect(delegate.stops, isEmpty);
        s.dispose();
      });
    });

    test('шим сам измерил блокировку (gap > 700 мс) → остановлен', () {
      final s = make();
      emit(s, {'t': 'hb', 'n': 10, 'gap': 650});
      expect(delegate.stops, isEmpty);
      emit(s, {'t': 'hb', 'n': 10, 'gap': 1200});
      expect(delegate.stops, [TgWidgetStopReason.watchdog]);
    });

    // Web: sandbox-iframe делит поток со страницей; долгий кадр Flutter шим
    // видит как свой разрыв тиков/longtask. Хост тоже опоздал → не виджет.
    test(
      'разрыв/longtask во время зависания хоста — виджет жив (ledger:RL-telegram-widgets)',
      () {
        fakeAsync((async) {
          final start = DateTime(2026, 11, 13);
          clock = start;
          final s = make();
          emit(s, {'t': 'loaded'});
          // Таймер хоста ещё не дотикал после 1,5 с стопа потока.
          clock = start.add(const Duration(milliseconds: 1500));
          emit(s, {'t': 'hb', 'n': 10, 'gap': 1500});
          emit(s, {'t': 'longtask', 'ms': 1400});
          expect(delegate.stops, isEmpty);
          // Таймер хоста дотикал и зафиксировал стоп — запоздавший отчёт шима
          // тоже не убивает виджет.
          async.elapse(const Duration(milliseconds: 250));
          clock = start.add(const Duration(milliseconds: 1750));
          emit(s, {'t': 'hb', 'n': 10, 'gap': 900});
          expect(delegate.stops, isEmpty);
          // Хост давно ровный, а шим снова встал на 1,2 с — это уже виджет.
          for (var i = 0; i < 20; i++) {
            async.elapse(const Duration(milliseconds: 250));
            clock = start.add(async.elapsed);
            emit(s, {'t': 'hb', 'n': 10, 'gap': 200});
          }
          emit(s, {'t': 'hb', 'n': 10, 'gap': 1200});
          expect(delegate.stops, [TgWidgetStopReason.watchdog]);
          s.dispose();
        });
      },
    );

    test('скрытый виджет сторож не трогает', () {
      fakeAsync((async) {
        final start = DateTime(2026, 11, 13);
        clock = start;
        final s = make();
        emit(s, {'t': 'loaded'});
        unawaited(s.setActive(false));
        for (var i = 0; i < 20; i++) {
          async.elapse(const Duration(milliseconds: 250));
          clock = start.add(async.elapsed);
        }
        expect(delegate.stops, isEmpty);
        s.dispose();
      });
    });

    test('DOM > 2000 узлов или longtask > 500 мс → остановлен', () {
      final s = make();
      emit(s, {'t': 'hb', 'n': 2001});
      expect(delegate.stops, [TgWidgetStopReason.domLimit]);
      final t = make();
      emit(t, {'t': 'longtask', 'ms': 900});
      expect(delegate.stops.last, TgWidgetStopReason.watchdog);
    });

    test('навигация в обход шима → остановлен', () {
      final s = make();
      s.onUnexpectedNavigation();
      expect(delegate.stops, [TgWidgetStopReason.navigation]);
    });
  });

  group('mxc', () {
    test(
      'проверенный бот, свой хоумсервер: картинка приходит base64',
      () async {
        delegate.media = (
          bytes: Uint8List.fromList(onePixelPng),
          mime: 'image/png',
        );
        final s = make(verified: true);
        emit(s, {'t': 'mxc', 'id': 1, 'url': 'mxc://example.invalid/abc'});
        await Future<void>.delayed(Duration.zero);
        final m = handle.sent.last;
        expect(m['t'], 'mxc');
        expect(m['b64'], base64Encode(onePixelPng));
        expect(m['mime'], 'image/png');
      },
    );

    // AC:RL-telegram-widgets/10
    test(
      'непроверенный бот, чужой хоумсервер или не mxc → картинки нет',
      () async {
        delegate.media = (
          bytes: Uint8List.fromList(onePixelPng),
          mime: 'image/png',
        );
        for (final c in [
          (false, 'mxc://example.invalid/abc'),
          (true, 'mxc://evil.example/abc'),
          (true, 'https://example.invalid/abc'),
        ]) {
          final s = make(verified: c.$1);
          emit(s, {'t': 'mxc', 'id': 1, 'url': c.$2});
          await Future<void>.delayed(Duration.zero);
          expect(handle.sent.last['t'], 'mxc', reason: c.$2);
          expect(handle.sent.last.containsKey('b64'), isFalse, reason: c.$2);
        }
      },
    );

    test(
      'зашифрованное/не-картинка (resolver вернул null) → не показывается',
      () async {
        delegate.media = null;
        final s = make(verified: true);
        emit(s, {'t': 'mxc', 'id': 3, 'url': 'mxc://example.invalid/enc'});
        await Future<void>.delayed(Duration.zero);
        expect(handle.sent.last['t'], 'mxc');
        expect(handle.sent.last.containsKey('b64'), isFalse);
      },
    );
  });
}
