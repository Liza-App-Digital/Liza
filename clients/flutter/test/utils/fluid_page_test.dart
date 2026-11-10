import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/events/fluid_page_card.dart';
import 'package:liza/pages/chat/fluid_page_view.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/fluid_page.dart';

import 'test_client.dart';

/// Страж «жидкого интерфейса»: события-страницы, доверие к отправителю,
/// проверка sha256, CSP, пропуск навигации и разовое авто-открытие.
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

  group('авто-открытие и свёртка списка', () {
    final manager = MiniAppManager.instance;
    setUp(manager.closeAll);

    bool isBot(String id) => id == '@bot:example.invalid';
    final openedAt = DateTime.now();
    bool decide(Event e, {bool side = true, String? roomId}) =>
        shouldAutoOpenLiveFluidPage(
          event: e,
          roomId: roomId ?? room.id,
          openedAt: openedAt,
          sideLayout: side,
          isBotOrAiUser: isBot,
        );

    test('живая страница от бота открывается ровно один раз на eventId', () {
      // AC:RL-liza-liquid-page/19
      final e = pageEvent(id: r'$auto1');
      expect(decide(e), isTrue);
      expect(decide(e), isFalse);
    });

    test(
      'история / до открытия чата — не открывается, eventId не сжигается',
      () {
        // AC:RL-liza-liquid-page/20
        final old = pageEvent(
          id: r'$auto2',
          ts: openedAt.subtract(const Duration(minutes: 5)),
        );
        expect(decide(old), isFalse);
        // Отстающие на несколько секунд часы сервера — всё ещё «живое».
        final skew = pageEvent(
          id: r'$auto3',
          ts: openedAt.subtract(const Duration(seconds: 3)),
        );
        expect(decide(skew), isTrue);
      },
    );

    test(
      'мультикейс отказа: не side / чужая комната / не бот / не страница',
      () {
        // AC:RL-liza-liquid-page/19
        final fresh = pageEvent(id: r'$auto4');
        expect(decide(fresh, side: false), isFalse);
        expect(decide(fresh, roomId: '!other:example.invalid'), isFalse);
        expect(
          decide(pageEvent(id: r'$auto5', sender: '@human:example.invalid')),
          isFalse,
        );
        expect(decide(pageEvent(id: r'$auto6', marker: 'none')), isFalse);
        // Отказы выше eventId не сожгли.
        expect(decide(fresh), isTrue);
      },
    );

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
      manager.openPage(pageEvent(id: r'$open1'), title: 'Цвета');
      expect(manager.activeApp?.kind, MiniAppKind.html);
      manager.expandChatList();
      expect(manager.chatListExpanded.value, isTrue);
      manager.closeAll();
      expect(manager.chatListExpanded.value, isFalse);
    });
  });
}
