import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/utils/liza_new_request.dart';

// Заявка Надежды 02.11: «+ Новый запрос» (меню шапки и строка списка чатов)
// открывает окно ввода запроса, а не создаёт пустой чат.
void main() {
  Future<String> tapAndGetLocation(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(
          path: '/start',
          builder: (_, _) => Builder(
            builder: (context) => TextButton(
              onPressed: () => openNewLizaRequest(context),
              child: const Text('go'),
            ),
          ),
        ),
        GoRoute(path: '/rooms', builder: (_, _) => const Text('panel')),
        GoRoute(
          path: AppRoutes.newRequest,
          builder: (_, _) => const Text('narrow'),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return router.state.uri.path;
  }

  testWidgets('компьютер: открывается пустая правая панель /rooms', (
    tester,
  ) async {
    expect(await tapAndGetLocation(tester, const Size(1600, 900)), '/rooms');
  });

  testWidgets('узкий экран: отдельный маршрут окна запроса', (tester) async {
    expect(
      await tapAndGetLocation(tester, const Size(400, 800)),
      AppRoutes.newRequest,
    );
  });
}
