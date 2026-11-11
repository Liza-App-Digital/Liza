// ignore_for_file: depend_on_referenced_packages
// ledger:RL-liza-liquid-page
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/fluid_page_view.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
import '../../utils/test_client.dart';

const html =
    '<!doctype html><html><head><title>Цвета</title></head>'
    '<body>красный</body></html>';

/// Отдаёт HTML страницы на скачивание медиа (FakeMatrixApi медиа не знает).
class PageMediaApi extends FakeMatrixApi {
  @override
  FutureOr<http.Response> mockIntercept(http.Request request) {
    if (request.url.path.contains('/download/')) {
      return http.Response.bytes(
        utf8.encode(html),
        200,
        headers: {'content-type': 'text/html'},
      );
    }
    return super.mockIntercept(request);
  }
}

/// Страница в отдельном окне ОС: тип окна в конфиге, документ по host-вызову
/// из главного окна, загрузка/ошибка/смена страницы во FluidPageView.
void main() {
  final manager = MiniAppManager.instance;
  final sha = sha256.convert(utf8.encode(html)).toString();
  late Client client;
  late Room room;

  Future<void> setup(WidgetTester tester) async {
    await tester.runAsync(() async {
      client = await prepareTestClient(
        loggedIn: true,
        httpClient: PageMediaApi(),
      );
    });
    room = Room(id: '!chat:example.invalid', client: client);
    manager.closeAll();
    manager.windowsSupported = true;
    addTearDown(() async {
      manager.closeAll();
      manager.windowsSupported = false;
      await client.dispose();
    });
  }

  Event pageEvent(String id) => Event.fromJson({
    'type': 'm.room.message',
    'event_id': id,
    'sender': '@bot:example.invalid',
    'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
    'room_id': room.id,
    'content': {
      'msgtype': 'm.file',
      'body': 'Страница: Цвета',
      'info': {'mimetype': 'text/html'},
      'url': 'mxc://example.invalid/abc',
      'com.liza.page': {'title': 'Цвета', 'sha256': sha},
    },
  }, room);

  Map<String, Object?> rpcArgs(MiniAppWindowConfig config) => {
    'app_id': config.appId,
    'content_key': config.contentKey,
    'session_id': config.interactiveSessionId,
    'account_user_id': client.userID,
  };

  testWidgets('конфиг окна страницы несёт kind=html туда-обратно', (
    tester,
  ) async {
    // AC:RL-liza-liquid-page/43
    await setup(tester);
    manager.openPage(pageEvent(r'$w1'), title: 'Цвета', allowDetach: true);
    final config = MiniAppWindowConfig.of(manager.detachedApps.single, null);
    expect(config.kind, MiniAppKind.html);
    final json = Map<String, Object?>.from(
      jsonDecode(jsonEncode(config.toJson())) as Map,
    );
    expect(json['kind'], 'html');
    final back = MiniAppWindowConfig.fromJson(json);
    expect(back.kind, MiniAppKind.html);
    expect(back.toJson(), config.toJson());
    // Окно, открытое старой сборкой (без ключа), — обычный mini App.
    final legacy = MiniAppWindowConfig.fromJson(json..remove('kind'));
    expect(legacy.kind, MiniAppKind.miniApp);
  });

  testWidgets(
    'fetchPageDocument отдаёт документ с CSP и отвергает устаревшее окно',
    (tester) async {
      // AC:RL-liza-liquid-page/44
      await setup(tester);
      manager.openPage(pageEvent(r'$w1'), title: 'Цвета', allowDetach: true);
      final first = MiniAppWindowConfig.of(manager.detachedApps.single, null);
      final document = await tester.runAsync(
        () => MiniAppWindows.instance.debugHandleHostCall(
          MethodCall('fetchPageDocument', rpcArgs(first)),
        ),
      );
      expect(document, isA<String>());
      expect(document as String, contains('Content-Security-Policy'));
      expect(document, contains('красный'));

      // В окно пришла другая страница — ответ по прежнему ключу не отдаём.
      manager.openPage(pageEvent(r'$w2'), title: 'Цвета', allowDetach: true);
      expect(manager.detachedApps.single.contentKey, isNot(first.contentKey));
      await expectLater(
        MiniAppWindows.instance.debugHandleHostCall(
          MethodCall('fetchPageDocument', rpcArgs(first)),
        ),
        throwsA(isA<StateError>()),
      );

      // Окно закрыли — страницы нет.
      final second = MiniAppWindowConfig.of(manager.detachedApps.single, null);
      manager.closeAll();
      await expectLater(
        MiniAppWindows.instance.debugHandleHostCall(
          MethodCall('fetchPageDocument', rpcArgs(second)),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  group('FluidPageView', () {
    setUp(() {
      FluidPageView.debugWebViewBuilder = (context, document) =>
          Text(document, key: const ValueKey('fluid-page-document'));
    });
    tearDown(() => FluidPageView.debugWebViewBuilder = null);

    // L10n грузится по-настоящему асинхронно — без runAsync кадр пуст.
    Future<void> settleL10n(WidgetTester tester) async {
      for (var i = 0; i < 50 && find.byType(Scaffold).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Widget app(Widget child) => MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: const Locale('ru'),
      home: Scaffold(body: child),
    );

    testWidgets('ошибка загрузки → «Повторить» → документ', (tester) async {
      // AC:RL-liza-liquid-page/45
      var calls = 0;
      await tester.pumpWidget(
        app(
          FluidPageView(
            pageKey: 'a',
            loadDocument: () async {
              calls++;
              if (calls == 1) throw StateError('сеть');
              return 'документ A';
            },
          ),
        ),
      );
      await settleL10n(tester);
      await tester.pump();
      expect(find.byKey(const ValueKey('fluid-page-error')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fluid-page-retry')));
      await tester.pump();
      await tester.pump();
      expect(calls, 2);
      expect(find.text('документ A'), findsOneWidget);
      expect(find.byKey(const ValueKey('fluid-page-error')), findsNothing);
    });

    testWidgets('смена страницы отбрасывает поздний ответ прежней', (
      tester,
    ) async {
      // AC:RL-liza-liquid-page/45
      final a = Completer<String>();
      final b = Completer<String>();
      Widget view(String key) => app(
        FluidPageView(
          pageKey: key,
          loadDocument: () => key == 'a' ? a.future : b.future,
        ),
      );
      await tester.pumpWidget(view('a'));
      await settleL10n(tester);
      expect(find.byKey(const ValueKey('fluid-page-loading')), findsOneWidget);
      await tester.pumpWidget(view('b'));
      b.complete('документ B');
      await tester.pump();
      a.complete('документ A');
      await tester.pump();
      expect(find.text('документ B'), findsOneWidget);
      expect(find.text('документ A'), findsNothing);
    });

    testWidgets('закрытие во время загрузки не падает', (tester) async {
      // AC:RL-liza-liquid-page/45
      final pending = Completer<String>();
      await tester.pumpWidget(
        app(FluidPageView(pageKey: 'a', loadDocument: () => pending.future)),
      );
      await settleL10n(tester);
      expect(find.byKey(const ValueKey('fluid-page-loading')), findsOneWidget);
      await tester.pumpWidget(app(const SizedBox()));
      pending.complete('поздно');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
