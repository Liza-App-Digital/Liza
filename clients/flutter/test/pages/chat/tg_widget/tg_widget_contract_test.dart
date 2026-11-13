// ledger:RL-telegram-widgets
//
// Контракт D13 (формат блока, подписанные байты), доверие (D4) и содержимое
// шима/обёртки (D8, профиль 1 Telegram).
import 'dart:convert';
import 'dart:io';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_engine_native.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_model.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_shim.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_trust.dart';

import 'tg_widget_test_support.dart';

void main() {
  group('D13: блок и подписанные байты', () {
    test(
      'канонический JSON совпадает с json.dumps(sort_keys, ensure_ascii=False)',
      () {
        final block = TgWidgetBlock.tryParse(
          widgetBlockJson(
            html: '<div>Привет</div>',
            height: 240,
            protectContent: true,
            sign: false,
          ),
        )!;
        // Эталон снят Python-ом сервера: json.dumps(o, sort_keys=True,
        // separators=(",", ":"), ensure_ascii=False).
        expect(
          block.signedPayload(),
          '{"allow_queries":true,"bot_id":"@shop_bot:example.invalid",'
          '"height":240,"html_sha256":'
          '"db73ed2510496f469d651d26233c4f1f1a7f3daaca425bb443f336be2f08251d",'
          '"is_shared":false,"protect_content":true,'
          '"room_id":"!w:example.invalid",'
          '"sender":"@shop_bot:example.invalid","v":1,"widget_id":"101",'
          '"width":0}',
        );
      },
    );

    test('блок не по контракту не разбирается (рисуется только body)', () {
      expect(TgWidgetBlock.tryParse(null), isNull);
      expect(TgWidgetBlock.tryParse({'widget_id': '1'}), isNull);
      final bad = widgetBlockJson()..['v'] = 2;
      expect(TgWidgetBlock.tryParse(bad), isNull);
      final noSig = widgetBlockJson()..['sig'] = '';
      expect(TgWidgetBlock.tryParse(noSig), isNull);
      final floatWidth = widgetBlockJson()..['width'] = 1.5;
      expect(TgWidgetBlock.tryParse(floatWidth), isNull);
      final noProtect = widgetBlockJson()..remove('protect_content');
      expect(TgWidgetBlock.tryParse(noProtect), isNull);
    });

    test('has_caption: отсутствие = true, false — только явный', () {
      expect(TgWidgetBlock.tryParse(widgetBlockJson())!.hasCaption, isTrue);
      expect(
        TgWidgetBlock.tryParse(widgetBlockJson(hasCaption: false))!.hasCaption,
        isFalse,
      );
    });

    test('пустая строка состояния = null', () {
      final b = TgWidgetBlock.tryParse(
        widgetBlockJson(chatData: '', publicData: ''),
      )!;
      expect(b.chatData, isNull);
      expect(b.publicData, isNull);
    });

    test('размеры: клампы 200–600 × 50–600, резерв 50 при авто', () {
      final auto = TgWidgetBlock.tryParse(widgetBlockJson())!;
      expect(TgWidgetSize.reservedHeight(auto), 50);
      expect(TgWidgetSize.clampHeight(240), 240);
      expect(TgWidgetSize.clampHeight(900), 600);
      expect(TgWidgetSize.clampHeight(10), 50);
      final fixed = TgWidgetBlock.tryParse(widgetBlockJson(height: 300))!;
      expect(TgWidgetSize.reservedHeight(fixed), 300);
    });
  });

  group('доверие: только подписанные виджеты', () {
    final keys = {testKid: testPublicKey};
    final verifier = FakeVerifier();

    TgWidgetTrustKind trustOf(
      Map<String, Object?> raw, {
      String sender = '@shop_bot:example.invalid',
      String room = '!w:example.invalid',
      Map<String, String>? withKeys,
    }) => evaluateTgWidgetTrust(
      block: TgWidgetBlock.tryParse(raw)!,
      eventSender: sender,
      eventRoomId: room,
      keys: withKeys ?? keys,
      verifier: verifier,
    );

    // AC:RL-telegram-widgets/6
    test(
      '∀ {неподписанный, подделанный html, неизвестный kid, чужой ключ} → только подпись',
      () {
        expect(
          trustOf(widgetBlockJson(sign: false)),
          TgWidgetTrustKind.captionOnly,
        );
        final tampered = widgetBlockJson()
          ..['html'] = '<script>steal()</script>';
        expect(trustOf(tampered), TgWidgetTrustKind.captionOnly);
        expect(
          trustOf(widgetBlockJson(kid: 'k-unknown')),
          TgWidgetTrustKind.captionOnly,
        );
        expect(
          trustOf(widgetBlockJson(), withKeys: {testKid: 'OTHER-KEY'}),
          TgWidgetTrustKind.captionOnly,
        );
        final resized = widgetBlockJson()..['height'] = 600;
        expect(trustOf(resized), TgWidgetTrustKind.captionOnly);
        final queries = widgetBlockJson()..['allow_queries'] = false;
        expect(trustOf(queries), TgWidgetTrustKind.captionOnly);
        // protect_content подписан: снять защиту правкой события нельзя.
        final unprotected = widgetBlockJson(protectContent: true)
          ..['protect_content'] = false;
        expect(trustOf(unprotected), TgWidgetTrustKind.captionOnly);
      },
    );

    test('state-поля не подписаны: правка chat_data подпись не ломает', () {
      final edited = widgetBlockJson()..['chat_data'] = '{"n":42}';
      expect(trustOf(edited), TgWidgetTrustKind.original);
    });

    test('оригинал vs пересланный (другой отправитель или другой чат)', () {
      expect(trustOf(widgetBlockJson()), TgWidgetTrustKind.original);
      expect(
        trustOf(widgetBlockJson(), sender: '@alice:example.invalid'),
        TgWidgetTrustKind.forwarded,
      );
      expect(
        trustOf(widgetBlockJson(), room: '!other:example.invalid'),
        TgWidgetTrustKind.forwarded,
      );
    });

    test('ошибка vodozemac = подпись не прошла (без исключения наружу)', () {
      const real = VodozemacTgWidgetVerifier();
      expect(
        real.verify(publicKey: 'not-a-key', message: 'x', signature: 'zz'),
        isFalse,
      );
    });
  });

  group('обёртка и шим', () {
    final doc = buildTgWidgetDocument(
      widgetHtml:
          '<!doctype html><html lang="en"><head>'
          '<link rel="prefetch" href="https://evil.example/p">'
          '<link rel="dns-prefetch" href="//evil.example">'
          '<link rel="preconnect" href="https://evil.example">'
          '<link rel="preload" href="https://evil.example/x" as="image">'
          '<meta http-equiv="refresh" content="0;url=https://evil.example">'
          '<base href="https://evil.example/">'
          '<style>.a{color:red}</style>'
          '<script src="https://evil.example/x.js"></script>'
          '<script>window.ok=1</script>'
          '</head><body class="b">'
          '<form action="https://evil.example"><input name="q"></form>'
          '<textarea></textarea><select><option>1</option></select>'
          '<iframe src="https://evil.example"></iframe>'
          '<audio src="https://evil.example/a.mp3"></audio>'
          '<video src="https://evil.example/v.mp4"></video>'
          '<dialog open>x</dialog><progress></progress><meter></meter>'
          '<object data="https://evil.example"></object><embed src="x">'
          '<div contenteditable="true" id="ce">edit</div>'
          '<img src="mxc://example.invalid/abc" id="m">'
          '<img src="https://evil.example/a.png" id="h">'
          '<button onclick="go()">Go</button>'
          '</body></html>',
      config: {
        'secret': 'abc',
        'chatData': '</script><script>alert(1)</script>',
      },
    );
    final head = doc.substring(doc.indexOf('<head>'), doc.indexOf('</head>'));
    final body = doc.substring(doc.indexOf('<body'));

    // AC:RL-telegram-widgets/5
    test('CSP — первый тег head, сеть закрыта, img только data:/blob:', () {
      expect(
        head.startsWith(
          '<head><meta http-equiv="Content-Security-Policy" content="',
        ),
        isTrue,
      );
      for (final d in [
        "default-src 'none'",
        "script-src 'unsafe-inline'",
        "style-src 'unsafe-inline'",
        'img-src data: blob:',
        "connect-src 'none'",
        "frame-src 'none'",
        "worker-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
      ]) {
        expect(tgWidgetCsp, contains(d));
      }
      expect(tgWidgetCsp, isNot(contains('unsafe-eval')));
      expect(tgWidgetCsp, isNot(contains('https:')));
      expect(head, contains('x-dns-prefetch-control" content="off"'));
      // Шим раньше любого скрипта виджета.
      expect(head.indexOf('var CFG = '), lessThan(head.indexOf('window.ok=1')));
    });

    // AC:RL-telegram-widgets/5
    test(
      '∀ prefetch/dns-prefetch/preconnect/preload, meta refresh, base, внешние скрипты — вырезаны',
      () {
        expect(doc, isNot(contains('rel="prefetch"')));
        expect(doc, isNot(contains('dns-prefetch" href')));
        expect(doc, isNot(contains('preconnect')));
        expect(doc, isNot(contains('preload')));
        expect(doc, isNot(contains('http-equiv="refresh"')));
        expect(doc, isNot(contains('<base')));
        expect(doc, isNot(contains('x.js')));
        expect(head, contains('<style>.a{color:red}</style>'));
      },
    );

    test('формы, ввод, фреймы, медиа, диалоги вне профиля — вырезаны', () {
      for (final tag in [
        '<form',
        '<input',
        '<textarea',
        '<select',
        '<option',
        '<iframe',
        '<audio',
        '<video',
        '<dialog',
        '<progress',
        '<meter',
        '<object',
        '<embed',
      ]) {
        expect(body, isNot(contains(tag)), reason: tag);
      }
      expect(body, isNot(contains('contenteditable')));
      expect(body, contains('<button onclick="go()">Go</button>'));
      expect(body, contains('class="b"'));
    });

    test('mxc в img уходит в data-tgw-mxc (браузер его не грузит сам)', () {
      expect(body, contains('data-tgw-mxc="mxc://example.invalid/abc"'));
      expect(body, isNot(contains('src="mxc://')));
    });

    test('данные в конфиге не закрывают <script> шима', () {
      expect(doc, isNot(contains('</script><script>alert(1)')));
      expect(doc, contains(r'\u003c/script>'));
    });

    // AC:RL-telegram-widgets/4
    test('TelegramWidget профиля 1: все поля, методы и события Telegram', () {
      const s = tgWidgetShimSource;
      for (final field in [
        'profile',
        'colorScheme',
        'themeParams',
        'isActive',
        'isPreview',
        'isForward',
        'chatType',
        'viewer',
        'publicData',
        'chatData',
        'HapticFeedback',
        'contentSafeAreaInset',
        'wallet',
        'theme',
      ]) {
        expect(s, contains('    $field: function () {'), reason: field);
      }
      for (final method in [
        'isProfileAtLeast',
        'watchPublicData',
        'unwatchPublicData',
        'request',
        'copyText',
        'openLink',
        'openTelegramLink',
        'setResizeAnchor',
        'ready',
        'onEvent',
        'offEvent',
        'onTheme',
      ]) {
        expect(s, contains(RegExp('\\b$method[:,]')), reason: method);
      }
      for (final event in [
        'themeChanged',
        'activated',
        'deactivated',
        'chatDataChanged',
        'publicDataChanged',
        'contentSafeAreaChanged',
      ]) {
        expect(s, contains("'$event'"), reason: event);
      }
      for (final code in ['NOT_ALLOWED', 'BUSY', 'FAILED']) {
        expect(s, contains("'$code'"), reason: code);
      }
      for (final h in [
        'impactOccurred',
        'notificationOccurred',
        'selectionChanged',
      ]) {
        expect(s, contains("'$h'"), reason: h);
      }
      for (final style in [
        'light',
        'medium',
        'heavy',
        'rigid',
        'soft',
        'error',
        'success',
        'warning',
      ]) {
        expect(s, contains("'$style'"), reason: style);
      }
      expect(s, contains('profile: function () { return 1; }'));
      expect(s, contains('wallet: function () { return null; }'));
      expect(s, isNot(contains('sendMessage')));
      // Объект заморожен и не переопределяется.
      expect(s, contains('Object.freeze(TW);'));
      expect(
        s,
        contains(
          "dp(W, 'TelegramWidget', { value: TW, writable: false, configurable: false",
        ),
      );
      // Лимит 16 обработчиков на тип и 1–64 байта данных запроса.
      expect(s, contains('handlers[type].length >= 16'));
      expect(s, contains('len < 1 || len > 64'));
      expect(s, contains("this.name = 'WidgetRequestError'"));
    });

    // AC:RL-telegram-widgets/5
    test(
      '∀ {fetch, XHR, WebSocket, EventSource, sendBeacon, RTCPeerConnection, Worker} → NetworkDisabledError; window.open — no-op',
      () {
        const s = tgWidgetShimSource;
        expect(s, contains("this.name = 'NetworkDisabledError'"));
        expect(
          s,
          contains("lock(W, 'fetch', function fetch() { netBlocked(); });"),
        );
        for (final api in [
          'XMLHttpRequest',
          'WebSocket',
          'EventSource',
          'RTCPeerConnection',
          'webkitRTCPeerConnection',
          'WebTransport',
          'Worker',
          'SharedWorker',
          'BroadcastChannel',
        ]) {
          expect(s, contains("'$api'"), reason: api);
        }
        expect(s, contains('lock(navigator, \'sendBeacon\''));
        expect(
          s,
          contains("lock(W, 'open', function open() { return null; });"),
        );
        // Свежий realm из iframe недоступен ни синхронно, ни через contentWindow.
        expect(s, contains("['contentWindow', 'contentDocument']"));
        expect(s, contains("guardInsert(Node.prototype, 'appendChild', [0]);"));
        expect(s, contains("lockGetter(Element.prototype, 'innerHTML'"));
        // Нет доступа к Liza: cookies, общие хранилища, мост mini app.
        expect(s, contains("lockGetter(o, 'cookie'"));
        expect(s, contains("lockGetter(W, 'indexedDB'"));
        expect(s, contains("lockGetter(W, 'localStorage'"));
        expect(s, isNot(contains('Liza.WebApp')));
        expect(s, isNot(contains('initData')));
        expect(s, contains('> CFG.quota'));
        expect(s, contains("'QuotaExceededError'"));
      },
    );

    test('тап: только доверенное событие, одно действие на тап', () {
      const s = tgWidgetShimSource;
      expect(
        s,
        contains(
          "W.addEventListener('pointerup', function (e) { if (e.isTrusted)",
        ),
      );
      expect(s, contains('e.isTrusted && e.detail > 0'));
      expect(s, contains('tap.used = true'));
    });

    // AC:RL-telegram-widgets/10
    test('LizaWidget — отдельный объект; has() — только по списку хоста', () {
      const s = tgWidgetShimSource;
      expect(s, contains("dp(W, 'LizaWidget'"));
      expect(
        s,
        contains(
          "lock(LW, 'has', function (feature) { return LIZA.indexOf(feature) >= 0; });",
        ),
      );
      // Фичи Liza не дописываются в TelegramWidget и не меняют profile.
      expect(s, isNot(contains("lock(TW, 'has'")));
      expect(s, isNot(contains('profile: function () { return 2')));
    });

    test('сторож: heartbeat, счётчик DOM, longtask', () {
      const s = tgWidgetShimSource;
      expect(
        s,
        contains("post({ t: 'hb', n: nodeCount, gap: Math.round(gap) })"),
      );
      expect(s, contains("post({ t: 'dom', n: nodeCount })"));
      expect(s, contains("'longtask'"));
    });
  });

  group('нативный WebView', () {
    // AC:RL-telegram-widgets/5
    test(
      'навигация: только первая загрузка about:blank, остальное — отказ',
      () {
        NavigationActionPolicy p(
          String url, {
          bool main = true,
          bool done = false,
        }) => tgWidgetNavigationPolicy(
          url: WebUri(url),
          isForMainFrame: main,
          initialLoadDone: done,
        );
        expect(p('about:blank'), NavigationActionPolicy.ALLOW);
        expect(p('about:blank', done: true), NavigationActionPolicy.CANCEL);
        expect(p('about:blank', main: false), NavigationActionPolicy.CANCEL);
        expect(p('https://example.com'), NavigationActionPolicy.CANCEL);
        expect(p('data:text/html,<b>x</b>'), NavigationActionPolicy.CANCEL);
        expect(p('javascript:alert(1)'), NavigationActionPolicy.CANCEL);
        expect(p('tg://resolve?domain=x'), NavigationActionPolicy.CANCEL);
      },
    );

    test('настройки: неперсистентно, сеть и окна закрыты', () {
      final s = tgWidgetWebViewSettings();
      expect(s.incognito, isTrue);
      expect(s.cacheEnabled, isFalse);
      expect(s.thirdPartyCookiesEnabled, isFalse);
      expect(s.domStorageEnabled, isFalse);
      expect(s.blockNetworkLoads, isTrue);
      expect(s.javaScriptCanOpenWindowsAutomatically, isFalse);
      expect(s.supportMultipleWindows, isFalse);
      expect(s.allowFileAccess, isFalse);
      expect(s.useShouldOverrideUrlLoading, isTrue);
      expect(s.useShouldInterceptRequest, isTrue);
    });
  });

  group('межъязыковая подпись (фикстура настоящего сервера)', () {
    final fixture =
        jsonDecode(
              File(
                'test/pages/chat/tg_widget/fixtures/sig_fixture.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final raw = Map<String, Object?>.from(fixture['block'] as Map);
    final key = (fixture['public_keys'] as List).first as Map;

    Uint8List b64(String s) => base64.decode(base64.normalize(s));

    /// Настоящий Ed25519 (чистый Dart): vodozemac на хосте без нативной
    /// библиотеки не грузится, а проверка должна быть криптографической.
    final realVerifier = _Ed25519Verifier();

    // AC:RL-telegram-widgets/6
    test(
      'каноникализация байт-в-байт = signed_bytes_utf8, тот же html_sha256',
      () {
        final block = TgWidgetBlock.tryParse(raw)!;
        expect(block.htmlSha256, fixture['html_sha256']);
        expect(
          utf8.encode(block.signedPayload()),
          utf8.encode(fixture['signed_bytes_utf8'] as String),
        );
      },
    );

    // AC:RL-telegram-widgets/6
    test('подпись сервера проверяется реальным Ed25519', () {
      final block = TgWidgetBlock.tryParse(raw)!;
      expect(b64(key['public_key'] as String), hasLength(32));
      expect(
        evaluateTgWidgetTrust(
          block: block,
          eventSender: block.sender,
          eventRoomId: block.roomId,
          keys: {key['kid'] as String: key['public_key'] as String},
          verifier: realVerifier,
        ),
        TgWidgetTrustKind.original,
      );
    });

    // AC:RL-telegram-widgets/6
    test(
      'подмена одного символа html (и protect_content) → подпись не сходится',
      () {
        final html = raw['html'] as String;
        final tampered = Map<String, Object?>.from(raw)
          ..['html'] = html.replaceFirst('мир', 'мip');
        final unprotected = Map<String, Object?>.from(raw)
          ..['protect_content'] = false;
        for (final r in [tampered, unprotected]) {
          final block = TgWidgetBlock.tryParse(r)!;
          expect(
            realVerifier.verify(
              publicKey: key['public_key'] as String,
              message: block.signedPayload(),
              signature: block.sig,
            ),
            isFalse,
          );
        }
      },
    );
  });

  group('сетевой выключатель движка (A)', () {
    // AC:RL-telegram-widgets/5
    test('перехват: пропускаем только data:/blob:/about:', () {
      for (final ok in [
        'data:image/png;base64,AA',
        'blob:null/1',
        'about:blank',
      ]) {
        expect(tgWidgetRequestAllowed(Uri.parse(ok)), isTrue, reason: ok);
      }
      for (final bad in [
        'https://evil.example/x',
        'http://127.0.0.1/',
        'wss://evil.example',
        'ftp://evil.example',
        'file:///etc/passwd',
        'mxc://example.invalid/a',
        'intent://x',
      ]) {
        expect(tgWidgetRequestAllowed(Uri.parse(bad)), isFalse, reason: bad);
      }
      expect(tgWidgetRequestAllowed(null), isFalse);
    });

    // AC:RL-telegram-widgets/5
    test('WKContentRuleList: блок «.*», исключение только data/blob/about', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final rules = tgWidgetContentBlockers();
      expect(rules.first.trigger.urlFilter, '.*');
      expect(rules.first.action.type, ContentBlockerActionType.BLOCK);
      expect(
        rules.last.action.type,
        ContentBlockerActionType.IGNORE_PREVIOUS_RULES,
      );
      final except = RegExp(rules.last.trigger.urlFilter);
      expect(except.hasMatch('data:text/html,x'), isTrue);
      expect(except.hasMatch('about:blank'), isTrue);
      expect(except.hasMatch('https://data.example/'), isFalse);
    });

    // AC:RL-telegram-widgets/5
    test('страховка: наши настройки чисты, любое ослабление — нарушение', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final p in TargetPlatform.values) {
        expect(
          tgWidgetSettingsViolations(
            tgWidgetWebViewSettings(platform: p),
            platform: p,
          ),
          isEmpty,
          reason: '$p',
        );
      }
      final weak = tgWidgetWebViewSettings(platform: TargetPlatform.iOS)
        ..blockNetworkLoads = false
        ..useShouldInterceptRequest = false
        ..contentBlockers = [];
      expect(
        tgWidgetSettingsViolations(weak, platform: TargetPlatform.iOS),
        containsAll([
          'blockNetworkLoads',
          'useShouldInterceptRequest',
          'contentBlockers',
        ]),
      );
    });

    // AC:RL-telegram-widgets/5
    testWidgets('без сетевого выключателя движок не создаётся', (tester) async {
      final weak = tgWidgetWebViewSettings()..blockNetworkLoads = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NativeTgWidgetEngine(
            debugSettings: weak,
            config: TgWidgetEngineConfig(
              document: '<p>x</p>',
              onMessage: (_) {},
              onCreated: (_) => fail('движок создан'),
              onPointer: (_) {},
              onActivation: () {},
              onUnexpectedNavigation: () {},
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('tg-widget-engine-refused')),
        findsOneWidget,
      );
      expect(find.byType(InAppWebView), findsNothing);
    });

    test(
      'Android: авто-затемнение выключено (тему задаёт color-scheme meta)',
      () {
        final s = tgWidgetWebViewSettings();
        expect(s.algorithmicDarkeningAllowed, isFalse);
        expect(s.forceDark, ForceDark.OFF);
      },
    );
  });

  group('шим: эмуляция профиля (C)', () {
    const s = tgWidgetShimSource;

    test('патчи — на прототипах и неконфигурируемые', () {
      expect(s, contains("[Document.prototype, D].forEach"));
      expect(
        s,
        contains(
          "['open', 'write', 'writeln'].forEach(function (n) { lock(o, n,",
        ),
      );
      expect(s, contains("lockGetter(o, 'designMode'"));
      expect(s, contains("lockGetter(Navigator.prototype, n"));
      expect(s, contains("lockGetter(Element.prototype, 'innerHTML'"));
      expect(s, contains("lockGetter(Element.prototype, 'outerHTML'"));
      expect(s, contains("lock(Element.prototype, 'insertAdjacentHTML'"));
      expect(s, contains("lockGetter(ShadowRoot.prototype, 'innerHTML'"));
      expect(
        s,
        contains("lock(Element.prototype, 'attachShadow', function () { throw"),
      );
      expect(s, contains("lock(DOMParser.prototype, 'parseFromString'"));
      expect(s, contains("lock(Range.prototype, 'createContextualFragment'"));
      expect(s, contains('configurable: false'));
    });

    test('MutationObserver — с document-start, до body', () {
      final observe = s.indexOf('mo.observe(D.documentElement');
      expect(observe, greaterThan(0));
      expect(
        observe,
        lessThan(s.indexOf("D.addEventListener('DOMContentLoaded'")),
      );
    });

    test(
      '<template shadowrootmode> вырезается (шим и предварительная чистка)',
      () {
        expect(s, contains("el.hasAttribute('shadowrootmode')"));
        final doc = buildTgWidgetDocument(
          widgetHtml:
              '<div><template shadowrootmode="open"><iframe></iframe></template>ok</div>',
          config: const {'secret': 'x'},
        );
        final body = doc.substring(doc.indexOf('<body'));
        expect(body, isNot(contains('shadowrootmode')));
        expect(body, isNot(contains('<iframe')));
        expect(body, contains('ok</div>'));
      },
    );

    test('confirm → false, prompt → null, openLink без user:pass@', () {
      expect(
        s,
        contains("lock(W, 'confirm', function confirm() { return false; });"),
      );
      expect(
        s,
        contains("lock(W, 'prompt', function prompt() { return null; });"),
      );
      expect(s, contains('if (u.username || u.password) throw new TypeError'));
    });

    test('превью: openLink/openTelegramLink/copyText/вибро — no-op', () {
      expect(
        s,
        contains("if (CFG.isPreview) return;\n    post({ t: 'openLink'"),
      );
      expect(
        s,
        contains("if (CFG.isPreview) return;\n      post({ t: 'copyText'"),
      );
      expect(s, contains("if (!CFG.isPreview) post({ t: 'haptic'"));
    });

    test(
      'скрытый виджет: rAF стоит, таймеры не чаще раза в 1 с; дрейф heartbeat',
      () {
        expect(s, contains('frames.push(cb);'));
        expect(s, contains('Math.max(1000, +ms || 0)'));
        expect(
          s,
          contains("post({ t: 'hb', n: nodeCount, gap: Math.round(gap) });"),
        );
      },
    );

    // AC:RL-telegram-widgets/4
    test('viewer заморожен и приходит от хоста', () {
      expect(s, contains('var VIEWER = CFG.viewer ? Object.freeze('));
      expect(s, contains('viewer: function () { return VIEWER; },'));
    });

    test('color-scheme meta по теме чата', () {
      final dark = buildTgWidgetDocument(
        widgetHtml: '<p>x</p>',
        config: const {'secret': 'x'},
        colorScheme: 'dark',
      );
      expect(dark, contains('<meta name="color-scheme" content="dark">'));
      expect(
        s,
        contains("origSetAttr.call(COLOR_META, 'content', m.colorScheme)"),
      );
    });
  });
}

class _Ed25519Verifier implements TgWidgetSignatureVerifier {
  @override
  bool verify({
    required String publicKey,
    required String message,
    required String signature,
  }) {
    try {
      return ed.verify(
        ed.PublicKey(base64.decode(base64.normalize(publicKey))),
        Uint8List.fromList(utf8.encode(message)),
        base64.decode(base64.normalize(signature)),
      );
    } catch (_) {
      return false;
    }
  }
}
