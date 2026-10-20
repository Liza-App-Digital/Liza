// Адреса пунктов настроек обязаны существовать в дереве маршрутов.
//
// Выстрадано: маршруты `email` и `handle` были вложены внутрь ветки
// `security`, то есть реально отвечали на /rooms/settings/security/email.
// Меню при этом вело на /rooms/settings/email — go_router такого адреса не
// находил и молча уводил в список чатов. Внешне это выглядело как «экран не
// открывается», а ни один тест не краснел: и меню, и маршруты по
// отдельности были корректны, расходились только их адреса.
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/config/app_config.dart';
import 'package:go_router/go_router.dart';

import 'package:liza/config/routes.dart';

/// Собирает полные пути всех маршрутов дерева.
Set<String> _collectPaths(List<RouteBase> routes, [String prefix = '']) {
  final paths = <String>{};
  for (final route in routes) {
    if (route is GoRoute) {
      final path = route.path.startsWith('/')
          ? route.path
          : '$prefix/${route.path}';
      paths.add(path.replaceAll('//', '/'));
      paths.addAll(_collectPaths(route.routes, path));
    } else {
      paths.addAll(_collectPaths(route.routes, prefix));
    }
  }
  return paths;
}

void main() {
  late Set<String> paths;

  setUpAll(() => paths = _collectPaths(AppRoutes.routes));

  group('адреса пунктов настроек существуют в дереве маршрутов', () {
    // Ровно те строки, которые стоят в context.go(...) пунктов меню
    // settings_view.dart. Расхождение = пункт уводит в список чатов.
    const menuTargets = [
      '/rooms/settings/email',
      '/rooms/settings/handle',
      '/rooms/settings/style',
      '/rooms/settings/notifications',
      '/rooms/settings/devices',
      '/rooms/settings/security',
    ];

    for (final target in menuTargets) {
      test(target, () {
        expect(
          paths,
          contains(target),
          reason:
              'пункт меню ведёт на $target, но такого маршрута нет — '
              'go_router уведёт в список чатов',
        );
      });
    }
  });

  // ledger:RL-mcp-showcase-entry-points
  // AC:RL-mcp-showcase-entry-points/5
  // Витрина MCP — отдельное окно вне ветки настроек (Надежда, В5 18.10): все
  // три входа («+», настройки, «⋮» в чате с Лизой) ходят по AppRoutes.mcp.
  test('витрина MCP: AppRoutes.mcp есть в дереве и не под /rooms/settings', () {
    expect(paths, contains(AppRoutes.mcp));
    expect(AppRoutes.mcp.startsWith('/rooms/settings'), isFalse);
    expect(paths, isNot(contains('/rooms/settings/integrations')));
  });

  // ledger:RL-keycloak-id-prod
  // AC:RL-keycloak-id-prod/4
  test('prod/dev имеют маршрут phone/email OTP с публичным адресом', () {
    expect(paths.contains('/auth/phone'), AppConfig.phoneAuthEnabled);
    expect(paths.where((path) => path.contains('demo')), isEmpty);
  });

  test('email и handle НЕ вложены в security', () {
    expect(paths, isNot(contains('/rooms/settings/security/email')));
    expect(paths, isNot(contains('/rooms/settings/security/handle')));
  });
}
