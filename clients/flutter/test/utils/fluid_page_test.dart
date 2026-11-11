import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/fluid_page_view.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/fluid_page.dart';

import 'test_client.dart';

/// Страж «жидкого интерфейса»: события-страницы, доверие к отправителю,
/// проверка sha256, CSP, пропуск навигации и открытие по клику окном ОС.
/// ledger:RL-liza-liquid-page
void main() {
  late Client client;
  late Room room;
  const html =
      '<!doctype html><html><head><title>Цвета</title></head>'
      '<body>красный</body></html>';
  final sha = sha256.convert(utf8.encode(html)).toString();

  setUpAll(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!chat:example.invalid', client: client);
  });

  Event pageEvent({
    String id = r'$p1',
    String sender = '@bot:example.invalid',
    String mime = 'text/html',
    String? marker,
    DateTime? ts,
    String msgtype = 'm.file',
  }) => Event.fromJson({
    'type': 'm.room.message',
    'event_id': id,
    'sender': sender,
    'origin_server_ts': (ts ?? DateTime.now()).millisecondsSinceEpoch,
    'room_id': room.id,
    'content': {
      'msgtype': msgtype,
      'body': 'Страница: Цвета',
      'info': {'mimetype': mime},
      'url': 'mxc://example.invalid/abc',
      if (marker != 'none')
        'com.liza.page': {'title': 'Цвета', 'sha256': marker ?? sha},
    },
  }, room);

  group('isFluidPageEvent / isFluidPageSender', () {
    test(
      'мультикейс — страницей считается только m.file text/html с маркером',
      () {
        // AC:RL-liza-liquid-page/16
        expect(isFluidPageEvent(pageEvent()), isTrue);
        expect(isFluidPageEvent(pageEvent(mime: 'application/pdf')), isFalse);
        expect(isFluidPageEvent(pageEvent(marker: 'none')), isFalse);
        expect(isFluidPageEvent(pageEvent(marker: 'XYZ')), isFalse);
        expect(isFluidPageEvent(pageEvent(msgtype: 'm.text')), isFalse);
      },
    );

    test('чужая/своя страница не доверена, бот — доверен', () {
      // AC:RL-liza-liquid-page/15
      bool isBot(String id) => id == '@bot:example.invalid';
      expect(isFluidPageSender(pageEvent(), isBotOrAiUser: isBot), isTrue);
      expect(
        isFluidPageSender(
          pageEvent(sender: '@human:example.invalid'),
          isBotOrAiUser: isBot,
        ),
        isFalse,
      );
      expect(
        isFluidPageSender(
          pageEvent(sender: client.userID!),
          isBotOrAiUser: (_) => true,
        ),
        isFalse,
      );
    });

    test('название из маркера', () {
      expect(fluidPageTitle(pageEvent()), 'Цвета');
    });
  });

  group('loadFluidPageHtml', () {
    test('верный sha256 — HTML отдаётся', () async {
      // AC:RL-liza-liquid-page/14
      final out = await loadFluidPageHtml(
        pageEvent(),
        download: (_) async => Uint8List.fromList(utf8.encode(html)),
      );
      expect(out, html);
    });

    test('подмена содержимого — отказ sha256-mismatch', () async {
      // AC:RL-liza-liquid-page/14
      await expectLater(
        loadFluidPageHtml(
          pageEvent(),
          download: (_) async => Uint8List.fromList(utf8.encode('${html}x')),
        ),
        throwsA(
          isA<FluidPageException>().having(
            (e) => e.reason,
            'reason',
            'sha256-mismatch',
          ),
        ),
      );
    });

    test('слишком большой файл — отказ до sha256', () async {
      // AC:RL-liza-liquid-page/14
      await expectLater(
        loadFluidPageHtml(
          pageEvent(),
          download: (_) async => Uint8List(kFluidPageMaxBytes + 1),
        ),
        throwsA(
          isA<FluidPageException>().having(
            (e) => e.reason,
            'reason',
            'too-large',
          ),
        ),
      );
    });

    test('сбой скачивания — FluidPageException', () async {
      // AC:RL-liza-liquid-page/14
      await expectLater(
        loadFluidPageHtml(
          pageEvent(),
          download: (_) async => throw StateError('x'),
        ),
        throwsA(isA<FluidPageException>()),
      );
    });
  });

  group('fluidPageDocument и навигация', () {
    test('CSP — первым элементом, свой doctype, doctype модели снят', () {
      // AC:RL-liza-liquid-page/7
      final doc = fluidPageDocument(html);
      expect(
        doc.startsWith(
          '<!doctype html><meta http-equiv="Content-Security-Policy" content="',
        ),
        isTrue,
      );
      expect(
        RegExp('<!doctype', caseSensitive: false).allMatches(doc).length,
        1,
      );
      expect(doc.contains("default-src 'none'"), isTrue);
      expect(doc.contains("connect-src 'none'"), isTrue);
      expect(doc.contains('script-src'), isFalse);
      expect(doc.endsWith('</html>'), isTrue);
    });

    test('разрешён только about:blank (initialData), остальное — отмена', () {
      // AC:RL-liza-liquid-page/17
      expect(fluidPageNavigationAllowed('about:blank'), isTrue);
      expect(fluidPageNavigationAllowed('https://evil.example/'), isFalse);
      expect(fluidPageNavigationAllowed('data:text/html,x'), isFalse);
      expect(fluidPageNavigationAllowed(null), isFalse);
    });
  });

  group('открытие по клику и свёртка списка', () {
    final manager = MiniAppManager.instance;
    setUp(() {
      manager.closeAll();
      manager.windowsSupported = true;
    });
    tearDown(() {
      manager.closeAll();
      manager.windowsSupported = false;
    });

    bool isBot(String id) => id == '@bot:example.invalid';

    test('клик по карточке на десктопе с окнами — отдельное окно, справа '
        'пусто', () {
      // AC:RL-liza-liquid-page/40
      manager.openPage(
        pageEvent(id: r'$w1'),
        title: 'Цвета',
        allowDetach: true,
      );
      expect(manager.apps, isEmpty, reason: 'панели справа быть не должно');
      expect(manager.detachedApps.single.kind, MiniAppKind.html);
      expect(manager.detachedApps.single.appUrl, r'$w1');
    });

    test('повторный клик — то же окно поднимается, второго нет; другая '
        'страница — в том же окне', () async {
      // AC:RL-liza-liquid-page/41
      final focus = <String>[];
      final sub = manager.windowFocusRequests.listen(focus.add);
      manager.openPage(
        pageEvent(id: r'$w2'),
        title: 'Цвета',
        allowDetach: true,
      );
      final first = manager.detachedApps.single.contentKey;
      manager.openPage(
        pageEvent(id: r'$w2'),
        title: 'Цвета',
        allowDetach: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(manager.detachedApps, hasLength(1));
      expect(manager.detachedApps.single.contentKey, first);
      expect(focus, contains(kFluidPageAppId));
      manager.openPage(
        pageEvent(id: r'$w3'),
        title: 'Числа',
        allowDetach: true,
      );
      expect(manager.detachedApps, hasLength(1));
      expect(manager.detachedApps.single.appUrl, r'$w3');
      expect(manager.detachedApps.single.contentKey, isNot(first));
      await sub.cancel();
    });

    test('место выбирается на каждом клике: окно → (PIN) панель → окно', () {
      // AC:RL-liza-liquid-page/42
      final e = pageEvent(id: r'$w4');
      manager.openPage(e, title: 'Цвета', allowDetach: true);
      expect(manager.detachedApps, hasLength(1));
      manager.openPage(e, title: 'Цвета', allowDetach: false);
      expect(manager.detachedApps, isEmpty);
      expect(manager.activeApp?.kind, MiniAppKind.html);
      manager.openPage(e, title: 'Цвета', allowDetach: true);
      expect(manager.apps, isEmpty);
      expect(manager.detachedApps, hasLength(1));
    });

    test('без поддержки окон ОС — панель (запасной путь)', () {
      // AC:RL-liza-liquid-page/42
      manager.windowsSupported = false;
      manager.openPage(
        pageEvent(id: r'$w5'),
        title: 'Цвета',
        allowDetach: true,
      );
      expect(manager.detachedApps, isEmpty);
      expect(manager.activeApp?.kind, MiniAppKind.html);
    });

    test('превью списка чатов — название страницы только для бота', () {
      // AC:RL-liza-liquid-page/21
      expect(fluidPagePreviewTitle(pageEvent(), isBotOrAiUser: isBot), 'Цвета');
      expect(
        fluidPagePreviewTitle(
          pageEvent(sender: '@human:example.invalid'),
          isBotOrAiUser: isBot,
        ),
        isNull,
      );
      expect(
        fluidPagePreviewTitle(pageEvent(marker: 'none'), isBotOrAiUser: isBot),
        isNull,
      );
      expect(fluidPagePreviewTitle(null, isBotOrAiUser: isBot), isNull);
    });

    test('растянутый вручную список сбрасывается, когда страница закрыта', () {
      // AC:RL-liza-liquid-page/9
      manager.windowsSupported = false;
      manager.openPage(
        pageEvent(id: r'$open1'),
        title: 'Цвета',
        allowDetach: false,
      );
      expect(manager.activeApp?.kind, MiniAppKind.html);
      manager.expandChatList();
      expect(manager.chatListExpanded.value, isTrue);
      manager.closeAll();
      expect(manager.chatListExpanded.value, isFalse);
    });
  });
}
