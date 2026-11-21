// Раскрытие «Подробнее» в карточке MCP — на РЕАЛЬНОМ экране, не на реплике.
//
// До этого файла витрина MCP не была покрыта НИЧЕМ: её можно было сломать
// полностью (потерять бейдж, тумблер, переполнить строку) и получить зелёный
// прогон. Соседние тесты (`chat_settings_mcp_item_test`, `settings_routes_test`)
// стерегут только пункт меню и маршрут.
//
// Требование владельца (2026-09-10, дословно): «рядом с бейджиком "бесплатно"
// разместить кнопку "Подробнее" по клику на которую карточка будет раскрыаться
// и в ней будет более детальное описание возможностей данного mcp, но краткое,
// вместе с тем должен быть перечень тематик и пример команд».
//
// ledger:RL-mcp-showcase-details

// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_integrations/settings_integrations.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/test_client.dart';

void main() {
  late Client client;
  late SharedPreferences store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    // Фоновый sync держит таймер живым и роняет тест на «A Timer is still
    // pending even after the widget tree was disposed».
    client.backgroundSync = false;
    store = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  /// Шрифт Ahem рисует каждый глиф квадратом в кегль, поэтому длинные русские
  /// строки переполняют там, где реальный шрифт укладывается. Глушим ровно
  /// overflow: настоящую вёрстку меряет Ярус B (визуальный baseline), а не
  /// widget-ассерт — иначе ложный красный заглушат вместе с настоящим.
  void ignoreAhemOverflow() {
    final defaultOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('A RenderFlex overflowed')) {
        return;
      }
      defaultOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = defaultOnError);
  }

  Future<void> pumpScreen(WidgetTester tester, {Locale locale = const Locale('ru')}) async {
    ignoreAhemOverflow();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Matrix(
            clients: [client],
            store: store,
            child: const SettingsIntegrationsPage(),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        locale: locale,
        localizationsDelegates: const [
          L10n.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10n.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// Matrix держит живой таймер; без разбора дерева тест падает на pending Timer.
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  }

  // AC:RL-mcp-showcase-details/1
  testWidgets('кнопка «Подробнее» стоит РЯДОМ с бейджем «Бесплатно»', (
    tester,
  ) async {
    await pumpScreen(tester);

    for (final id in ['vkusvill', 'xl']) {
      final badge = find.byKey(Key('mcpBadge_$id'));
      final btn = find.byKey(Key('mcpDetailsBtn_$id'));
      expect(badge, findsOneWidget, reason: 'нет бейджа у $id');
      expect(btn, findsOneWidget, reason: 'нет кнопки «Подробнее» у $id');

      // Буква требования владельца «рядом с бейджиком»: один ряд ⇒ центры
      // совпадают по вертикали. Порог 1.0 — на доли пикселя от деления.
      final dy = (tester.getCenter(badge).dy - tester.getCenter(btn).dy).abs();
      expect(
        dy,
        lessThanOrEqualTo(1.0),
        reason: 'кнопка и бейдж у $id не в одном ряду (Δy=$dy)',
      );
    }
    await teardownTree(tester);
  });

  // AC:RL-mcp-showcase-details/2
  testWidgets('тап раскрывает описание, тематики и примеры; повторный сворачивает', (
    tester,
  ) async {
    await pumpScreen(tester);
    // ⚠️ l10n.yaml → use-deferred-loading: true: голый `await
    // L10n.delegate.load()` под testWidgets ВИСНЕТ вечно (fake-async не
    // прокручивает deferred-загрузку). Только через runAsync.
    final l10n = (await tester.runAsync(
      () => L10n.delegate.load(const Locale('ru')),
    ))!;

    // До тапа блока нет.
    expect(find.text(l10n.settingsMcpTopics), findsNothing);
    expect(find.text(l10n.settingsMcpEx_vkusvill_milk), findsNothing);

    await tester.tap(find.byKey(const Key('mcpDetailsBtn_vkusvill')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.settingsMcpAboutVkusvill), findsOneWidget);
    expect(find.text(l10n.settingsMcpTopics), findsOneWidget);
    // По тематике на каждый из 8 тулов сервера (с 2026-09-11): мультикейс по
    // всем новым, а не один пример — их можно потерять по одной.
    for (final topic in [
      l10n.settingsMcpTopic_vkusvill_search,
      l10n.settingsMcpTopic_vkusvill_shops,
      l10n.settingsMcpTopic_vkusvill_recipes,
      l10n.settingsMcpTopic_vkusvill_discount,
      l10n.settingsMcpTopic_vkusvill_analogs,
      l10n.settingsMcpTopic_vkusvill_barcode,
    ]) {
      expect(find.text(topic), findsOneWidget, reason: 'нет тематики «$topic»');
    }
    expect(find.text(l10n.settingsMcpLimitsVkusvill), findsOneWidget,
        reason: 'строка «чего пока не умеет» обязательна: доставку и оплату в '
            'чате не делает ни один из 8 тулов, без оговорки витрина соврёт');
    expect(find.text(l10n.settingsMcpEx_vkusvill_milk), findsOneWidget);
    expect(find.text(l10n.settingsMcpEx_vkusvill_shop), findsOneWidget);

    await tester.tap(find.byKey(const Key('mcpDetailsBtn_vkusvill')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsMcpTopics), findsNothing);

    await teardownTree(tester);
  });

  // AC:RL-mcp-showcase-details/3
  testWidgets('карточка XL: адресат назван, блока примеров нет', (tester) async {
    await pumpScreen(tester);
    // ⚠️ l10n.yaml → use-deferred-loading: true: голый `await
    // L10n.delegate.load()` под testWidgets ВИСНЕТ вечно (fake-async не
    // прокручивает deferred-загрузку). Только через runAsync.
    final l10n = (await tester.runAsync(
      () => L10n.delegate.load(const Locale('ru')),
    ))!;

    await tester.tap(find.byKey(const Key('mcpDetailsBtn_xl')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.settingsMcpAboutXl), findsOneWidget);
    // У XL нет allowlist и он вообще не может быть включён для Лизы, поэтому
    // обещать тематики/примеры нечем — но адресата назвать ОБЯЗАНЫ, иначе
    // пользователь пойдёт писать команды не в тот чат.
    expect(find.text(l10n.settingsMcpAddresseeLiza), findsOneWidget);
    expect(find.text(l10n.settingsMcpExamples), findsNothing,
        reason: 'у XL блока примеров быть не должно');

    await teardownTree(tester);
  });

  // AC:RL-mcp-showcase-details/2 (независимость осей раскрытия)
  testWidgets('раскрытие деталей и форма ключа не конфликтуют', (tester) async {
    await pumpScreen(tester);
    // ⚠️ l10n.yaml → use-deferred-loading: true: голый `await
    // L10n.delegate.load()` под testWidgets ВИСНЕТ вечно (fake-async не
    // прокручивает deferred-загрузку). Только через runAsync.
    final l10n = (await tester.runAsync(
      () => L10n.delegate.load(const Locale('ru')),
    ))!;

    // Раскрыли форму ключа XL (тап по trailing-иконке).
    await tester.tap(find.byIcon(Icons.add_circle_outline).last);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // Теперь «Подробнее» — форма уступает место (взаимное вытеснение),
    // но это РАЗНЫЕ поля: детали открылись, а не показалась форма ключа.
    await tester.tap(find.byKey(const Key('mcpDetailsBtn_xl')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsMcpAboutXl), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await teardownTree(tester);
  });
}
