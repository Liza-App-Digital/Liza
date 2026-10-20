import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/main.dart' as app;
import 'package:liza/pages/settings_integrations/settings_integrations.dart';

import 'liza_flows.dart';

/// Подключение MCP-расширения на РЕАЛЬНОМ бинаре против ЖИВОГО Synapse.
///
/// Воспроизводит жалобу владельца 2026-09-10 дословно: «нажимаю плюсик, чтобы
/// подключить, но ничего не происходит».
///
/// ⚠️⚠️ ЧЕСТНО О ГРАНИЦАХ ЭТОГО ТЕСТА — прочитай, прежде чем на него
/// полагаться. Это **сквозной смоук** (реальные тапы, настоящий Synapse), а
/// НЕ страж исходного дефекта. Проверено: с ОТКАЧЕННЫМ фиксом он остаётся
/// ЗЕЛЁНЫМ (2026-09-10). Причина конкретная и стоит того, чтобы её знать:
///
///  • дедупликация в Synapse срабатывает при равенстве **ТЕКУЩЕМУ**
///    состоянию, а не «такое значение когда-то было». В сценарии ниже между
///    подключениями стоит `enabled:[]`, поэтому третий шаг пишет значение,
///    отличное от текущего, — событие создаётся, sync его приносит, и
///    старый код тоже проходит;
///  • второе условие дефекта — расхождение кеша с сервером на **partial**
///    комнате. DM здесь создаётся тут же и partial не бывает.
///
/// Воспроизвести оба условия разом умеет widget-страж
/// `test/pages/settings_integrations/mcp_connection_state_source_test.dart`
/// (там комната намеренно partial, а sync-эхо не приходит) — red-proof
/// именно у него. Не переписывай этот файл в «страж», не воспроизведя
/// расхождение: зелёный тут ничего не доказывает про тот баг.
///
/// Ценность файла — в другом: он ловит поломки, до которых widget-тест не
/// достаёт (маршрут, живой Synapse, права на запись state, реальный тап).
///
/// Требует локального стека (`make local-up && make local-seed`) и запуска с
/// `--dart-define=APP_ENV=local`.
///
/// Родственная запись реестра — RL-mcp-connection-state-source (страж там,
/// этот файл — смоук).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MCP: «+» подключает ВкусВилл, и повтор не залипает', (
    tester,
  ) async {
    app.main();
    await tester.ensureLizaHome();

    // На экран витрины идём маршрутом, а не пробиваясь тапами через меню
    // аккаунта: путь до пункта настроек стерегут отдельные тесты, а здесь
    // предмет проверки — сама карточка.
    final ctx = tester.element(find.byType(Navigator).first);
    GoRouter.of(ctx).go(AppRoutes.mcp);
    await tester.pump(const Duration(milliseconds: 700));

    await tester.waitUntil(
      find.byType(SettingsIntegrationsPage),
      timeout: const Duration(seconds: 30),
    );
    // Дать экрану спросить состояние у сервера.
    await tester.pump(const Duration(seconds: 2));

    final badge = find.byKey(const Key('mcpBadge_vkusvill'));
    await tester.waitUntil(badge, timeout: const Duration(seconds: 30));

    Finder cardIcon(IconData icon) => find.descendant(
      of: find.ancestor(of: badge, matching: find.byType(Card)),
      matching: find.byIcon(icon),
    );

    Future<void> tapAction(IconData icon, String what) async {
      final f = cardIcon(icon);
      expect(f, findsOneWidget, reason: 'нет кнопки «$what» у ВкусВилла');
      await tester.tap(f);
      // Запись идёт под модальным showFutureLoadingDialog — ждём её конца.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 2));
    }

    // Приводим к известному старту: если расширение уже включено — выключаем.
    if (cardIcon(Icons.check_circle).evaluate().isNotEmpty) {
      await tapAction(Icons.check_circle, 'Отключить');
    }
    expect(
      cardIcon(Icons.add_circle_outline),
      findsOneWidget,
      reason: 'предусловие: ВкусВилл должен быть отключён',
    );

    // ── Шаг 1: подключение ──────────────────────────────────────────────
    await tapAction(Icons.add_circle_outline, 'Подключить');
    expect(
      cardIcon(Icons.check_circle),
      findsOneWidget,
      reason: 'после тапа по «+» карточка обязана стать подключённой — '
          'ровно это и «не происходило» у владельца',
    );

    // ── Шаг 2: отключение ───────────────────────────────────────────────
    await tapAction(Icons.check_circle, 'Отключить');
    expect(
      cardIcon(Icons.add_circle_outline),
      findsOneWidget,
      reason: 'отключение не отразилось на карточке',
    );

    // ── Шаг 3: повторное подключение ────────────────────────────────────
    // ⚠️ Это НЕ проверка дедупликации (см. шапку файла: Synapse сравнивает с
    // ТЕКУЩИМ состоянием, а оно сейчас `[]`). Шаг ловит другое — залипание
    // экрана на повторном цикле: сброшенное поле состояния, невоссозданный
    // ValueKey, неснятый `pending`.
    await tapAction(Icons.add_circle_outline, 'Подключить');
    expect(
      cardIcon(Icons.check_circle),
      findsOneWidget,
      reason: 'повторное подключение залипло на втором цикле',
    );
  });
}
