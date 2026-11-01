// ignore_for_file: depend_on_referenced_packages
// ledger:RL-xl-button-url-inapp-webview
//
// Страж: url-кнопка бота (`com.liza.xl_buttons`, в т.ч. «Оплатить» с payment_url
// формы Prodamus) открывается ВНУТРИ мессенджера (встроенный ExternalLinkWebView),
// а не в системном браузере. non-https → fallback UrlLauncher. Action-кнопка без
// url → по-прежнему шлёт index текстом. Кнопки видны только у ботов роли `ai`.
//
// Проверяем РЕАЛЬНУЮ навигацию (production `openXlButtonUrl`) и РЕАЛЬНЫЙ виджет
// `XlButtonsContent`, а не реплику логики.
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/xl_buttons_content.dart';
import 'package:liza/pages/chat/external_link_web_view.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/test_client.dart';
import '../../utils/registered_bot_test_transport.dart';

/// Фейк url_launcher: перехватывает внешний запуск, чтобы (а) утверждать
/// fallback-путь и (б) не бить платформенный канал в тесте.
class _FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return true;
  }

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

/// Фейк-платформа `flutter_inappwebview`: `InAppWebView` строится в пустой бокс,
/// чтобы `ExternalLinkWebView` можно было пампить в host-тесте (реальный webview
/// требует нативной платформы, которой в unit-прогоне нет).
class _FakeInAppWebViewPlatform extends InAppWebViewPlatform
    with MockPlatformInterfaceMixin {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _FakeInAppWebViewWidget(params);
}

class _FakeInAppWebViewWidget extends PlatformInAppWebViewWidget
    with MockPlatformInterfaceMixin {
  _FakeInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// Хост без L10n — для прямой проверки навигации `openXlButtonUrl`.
Widget _hostFor(void Function(BuildContext) onTap) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) =>
          ElevatedButton(onPressed: () => onTap(ctx), child: const Text('go')),
    ),
  ),
);

void main() {
  setUp(installRegisteredBotTestTransport);
  tearDown(resetRegisteredBotTestTransport);
  late _FakeUrlLauncher fakeLauncher;

  setUp(() {
    fakeLauncher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = fakeLauncher;
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  testWidgets(
    'AC-1: https url-кнопка → открывает ExternalLinkWebView (не браузер)',
    (tester) async {
      // AC:RL-xl-button-url-inapp-webview/1
      await tester.pumpWidget(
        _hostFor(
          (ctx) => openXlButtonUrl(ctx, 'https://demo.payform.ru/pay/abc123'),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle(); // достроить переход на маршрут webview

      expect(find.byType(ExternalLinkWebView), findsOneWidget);
      expect(fakeLauncher.launched, isEmpty); // внешний браузер НЕ вызван
    },
  );

  testWidgets(
    'AC-2: non-https url-кнопка → fallback UrlLauncher, webview НЕ открывается',
    (tester) async {
      // AC:RL-xl-button-url-inapp-webview/2
      await tester.pumpWidget(
        _hostFor((ctx) => openXlButtonUrl(ctx, 'tel:+79001234567')),
      );
      await tester.pump();
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(find.byType(ExternalLinkWebView), findsNothing);
      expect(fakeLauncher.launched, contains('tel:+79001234567'));
    },
  );

  testWidgets(
    'AC-1 (мультикейс): payment_url и обычная https-форма — обе in-app',
    (tester) async {
      // AC:RL-xl-button-url-inapp-webview/1
      // AC:RL-xl-button-url-inapp-webview/5
      for (final url in [
        'https://demo.payform.ru/pay/xyz',
        'https://forms.yandex.ru/cloud/abc',
      ]) {
        await tester.pumpWidget(_hostFor((ctx) => openXlButtonUrl(ctx, url)));
        await tester.pump();
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        expect(
          find.byType(ExternalLinkWebView),
          findsOneWidget,
          reason: 'in-app ожидается для $url',
        );
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }
      expect(fakeLauncher.launched, isEmpty);
    },
  );

  group('полный виджет XlButtonsContent', () {
    Widget wrap(Widget child, MatrixState m) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<MatrixState>.value(
        value: m,
        child: Scaffold(body: child),
      ),
    );

    Event card(
      Room room,
      String senderId,
      List<Map<String, Object?>> buttons,
    ) => Event(
      type: EventTypes.Message,
      content: {
        'msgtype': 'm.text',
        'body': 'Оплатить заказ',
        'com.liza.xl_buttons': buttons,
        'com.liza.xl_text_html': 'Оплатить заказ',
      },
      eventId: '\$xl1',
      senderId: senderId,
      originServerTs: DateTime.now(),
      room: room,
    );

    testWidgets(
      'точный системный MXID сохраняет legacy XL; чужой домен и новый web_app не доверены',
      (tester) async {
        // AC:RL-bot-api-interactive-client/10
        late Client client;
        await tester.runAsync(() async {
          client = await prepareTestClient(loggedIn: true);
        });
        addTearDown(client.dispose);
        final room = Room(id: '!legacy:hs', client: client);
        Future<void> show(String sender) async {
          final event = card(room, sender, [
            {'index': '1', 'title': 'Legacy', 'callback': true},
          ]);
          event.content['com.liza.bot_markup'] = {
            'inline_keyboard': [
              [
                {
                  'text': 'Private app',
                  'web_app': {'url': 'https://app.example'},
                },
              ],
            ],
          };
          await tester.pumpWidget(
            wrap(
              XlButtonsContent(
                event: event,
                textColor: Colors.black,
                linkColor: Colors.blue,
              ),
              MatrixState(),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
        }

        await show('@liza:bots.liza.ru');
        expect(find.widgetWithText(OutlinedButton, 'Legacy'), findsOneWidget);
        expect(
          find.widgetWithText(OutlinedButton, 'Private app'),
          findsNothing,
        );
        await show('@liza:evil.example');
        expect(find.widgetWithText(OutlinedButton, 'Legacy'), findsNothing);
      },
    );

    testWidgets(
      'AC-4: не-ai отправитель → кнопки НЕ рисуются (плоский текст)',
      (tester) async {
        // AC:RL-xl-button-url-inapp-webview/4
        late final Client client;
        await tester.runAsync(() async {
          client = await prepareTestClient(loggedIn: true);
        });
        addTearDown(client.dispose);
        final room = Room(id: '!r:liza.local', client: client);

        await tester.pumpWidget(
          wrap(
            XlButtonsContent(
              event: card(room, '@human:liza.local', [
                {
                  'index': 'pay',
                  'title': 'Оплатить',
                  'url': 'https://x.payform.ru/p',
                },
              ]),
              textColor: const Color(0xFF000000),
              linkColor: const Color(0xFF0000FF),
            ),
            MatrixState(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.widgetWithText(OutlinedButton, 'Оплатить'), findsNothing);
      },
    );

    testWidgets('AC-4: ai-бот → кнопка «Оплатить» рисуется', (tester) async {
      // AC:RL-xl-button-url-inapp-webview/4
      late final Client client;
      await tester.runAsync(() async {
        client = await prepareTestClient(loggedIn: true);
      });
      addTearDown(client.dispose);
      final room = Room(id: '!r:liza.local', client: client);

      await tester.pumpWidget(
        wrap(
          XlButtonsContent(
            event: card(room, '@bot_father:liza.local', [
              {
                'index': 'pay',
                'title': 'Оплатить',
                'url': 'https://x.payform.ru/p',
              },
            ]),
            textColor: const Color(0xFF000000),
            linkColor: const Color(0xFF0000FF),
          ),
          MatrixState(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.widgetWithText(OutlinedButton, 'Оплатить'), findsOneWidget);
    });

    testWidgets(
      'AC-3: action-кнопка без url → шлёт index текстом (webview не открыт)',
      (tester) async {
        // AC:RL-xl-button-url-inapp-webview/3
        late final Client client;
        await tester.runAsync(() async {
          client = await prepareTestClient(loggedIn: true);
        });
        addTearDown(client.dispose);
        final room = Room(id: '!r:liza.local', client: client);
        // Регистрируем комнату в клиенте, иначе sendTextEvent не долетает до
        // fake-transport (client.rooms пуст без sync).
        client.rooms.add(room);

        await tester.pumpWidget(
          wrap(
            XlButtonsContent(
              event: card(room, '@bot_father:liza.local', [
                {'index': 'bofood_checkout', 'title': 'Оформить'},
              ]),
              textColor: const Color(0xFF000000),
              linkColor: const Color(0xFF0000FF),
            ),
            MatrixState(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        final btn = find.widgetWithText(OutlinedButton, 'Оформить');
        expect(btn, findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(btn);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();
        });

        // ПОЗИТИВНО: callback-суррогат реально отправил index текстом (PUT в
        // /send/m.room.message с телом, содержащим index) — не только «не открыл
        // webview». Без этого страж зелен и при удалении sendTextEvent.
        final sent = FakeMatrixApi.calledEndpoints.entries
            .where((e) => e.key.contains('/send/m.room.message/'))
            .expand((e) => e.value)
            .map((b) => b.toString())
            .toList();
        expect(
          sent.any((b) => b.contains('bofood_checkout')),
          isTrue,
          reason: 'action-кнопка должна слать index текстом',
        );
        // И не открывает webview / не дёргает браузер.
        expect(find.byType(ExternalLinkWebView), findsNothing);
        expect(fakeLauncher.launched, isEmpty);
      },
    );

    // AC-6 (debounce двойного тапа) — MANUAL: детерминированный widget-тест
    // невозможен (после первого тапа webview накрывает кнопку → второй тап
    // всегда мимо, тест был бы зелен и без фикса = ложный страж). Debounce
    // `_busy` в `_XlButtonsContentState` проверяется code-review + device-flow
    // (ручной двойной тап). См. RL-xl-button-url-inapp-webview AC-6 [manual].
  });
}
