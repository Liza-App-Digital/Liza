// ledger:RL-empty-panel-new-request
// AC:RL-empty-panel-new-request/17
// guard.render:real-widget
//
// Кроссфейд «пустая панель → чат-запрос» (видео Надежды 23.10: «резкий
// переход»). Настоящий AppRoutes.chatPageBuilder под GoRouter в column-mode:
// отмеченная панелью комната проявляется, остальные открываются мгновенно,
// повторный pageBuilder не пересоздаёт страницу.
//
// Red-proof:
//   RP-1: отдавать в pageBuilder разный класс страницы по токену
//     (NoTransitionPage без него) → после протухания токена ресайз окна
//     пересоздаёт ChatPage, `mounts` = 2, красный.
//   RP-2: fade для любой комнаты → «другой чат мгновенно» красный.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/utils/new_request_transition.dart';

void main() {
  tearDown(NewRequestTransition.reset);

  group('токен', () {
    test('280 мс для отмеченной комнаты в течение 1,5 с, иначе 0', () {
      var now = DateTime(2026, 10, 23, 12);
      NewRequestTransition.now = () => now;
      expect(NewRequestTransition.durationFor('!a'), Duration.zero);
      NewRequestTransition.arm('!a');
      expect(NewRequestTransition.durationFor('!a'), NewRequestTransition.fade);
      // Повторное чтение даёт тот же ответ: pageBuilder зовётся не раз.
      expect(NewRequestTransition.durationFor('!a'), NewRequestTransition.fade);
      expect(NewRequestTransition.durationFor('!b'), Duration.zero);
      now = now.add(const Duration(milliseconds: 1600));
      expect(NewRequestTransition.durationFor('!a'), Duration.zero);
    });
  });

  group('страница чата в column-mode', () {
    late int mounts;
    late int builds;

    Future<GoRouter> pumpRouter(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      mounts = 0;
      builds = 0;
      final router = GoRouter(
        initialLocation: '/rooms',
        routes: [
          GoRoute(
            path: '/rooms',
            builder: (_, _) => const Text('panel'),
            routes: [
              GoRoute(
                path: ':roomid',
                pageBuilder: (context, state) {
                  builds++;
                  return AppRoutes.chatPageBuilder(
                    context,
                    state,
                    _Chat(
                      state.pathParameters['roomid']!,
                      onMount: () => mounts++,
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      return router;
    }

    double chatOpacity(WidgetTester tester, String roomId) {
      final fades = find.ancestor(
        of: find.text('chat $roomId'),
        matching: find.byType(FadeTransition),
      );
      return fades
          .evaluate()
          .map((e) => (e.widget as FadeTransition).opacity.value)
          .fold(1.0, (a, b) => a * b);
    }

    testWidgets('из панели — кроссфейд: панель ещё видна под чатом', (
      tester,
    ) async {
      final router = await pumpRouter(tester);
      NewRequestTransition.arm('!a');
      router.go('/rooms/!a');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = chatOpacity(tester, '!a');
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));
      expect(find.text('panel'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(chatOpacity(tester, '!a'), 1);
    });

    testWidgets('другой чат — мгновенно', (tester) async {
      final router = await pumpRouter(tester);
      NewRequestTransition.arm('!a');
      router.go('/rooms/!b');
      await tester.pump();
      await tester.pump();
      expect(chatOpacity(tester, '!b'), 1);
    });

    testWidgets(
      'повторный pageBuilder (в окне токена и после) — без пересоздания',
      (tester) async {
        var now = DateTime(2026, 10, 23, 12);
        NewRequestTransition.now = () => now;
        final router = await pumpRouter(tester);
        NewRequestTransition.arm('!a');
        router.go('/rooms/!a');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // Ресайз в пределах column-mode: pageBuilder зависит от MediaQuery и
        // зовётся снова — в окне токена и после его протухания.
        final before = builds;
        tester.view.physicalSize = const Size(1300, 900);
        await tester.pump();
        now = now.add(const Duration(seconds: 2));
        tester.view.physicalSize = const Size(1200, 900);
        await tester.pump();
        await tester.pump();
        expect(
          builds,
          greaterThan(before + 1),
          reason: 'pageBuilder перевызван',
        );
        expect(find.text('chat !a'), findsOneWidget);
        expect(mounts, 1);
      },
    );
  });
}

class _Chat extends StatefulWidget {
  const _Chat(this.roomId, {required this.onMount});
  final String roomId;
  final VoidCallback onMount;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Colors.white, child: Text('chat ${widget.roomId}'));
}
