// ignore_for_file: depend_on_referenced_packages
//
// Страж RL-bot-ai-badge-real-ai-only: плашка роли `ai` рядом с именем.
//   • localpart ∈ {liza} (gpt/deepseek выведены 2026-11-13) → каталожный тег «ИИ»;
//   • прочие носители роли `ai` (боты BotFather, /newbot, @support, @cup,
//     вручную помеченные люди) → зелёная плашка «Бот» (клиентский L10n-текст);
//   • роль `user` / роль не загружена → плашки нет.
// Роль `ai` у не-AI держится ради поведения (нативные кнопки через isAiUser),
// но признаком ИИ для пользователя не является. Рендерит РЕАЛЬНЫЙ прод-виджет
// UserRoleBadge через Matrix.of(context).
// ledger:RL-bot-ai-badge-real-ai-only

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/user_role_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/user_role_badge.dart';

import '../utils/test_client.dart';

// UserRoleBadge для реального пути (userId != null) резолвит роль через
// Matrix.of(context).userRoleService. Поднимать полный Matrix-виджет в
// юнит-тесте неоправданно тяжело — подменяем только то, что читает бейдж:
// геттеры client и userRoleService.
class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client, this._roleService);

  final Client _client;
  final UserRoleService _roleService;

  @override
  Client get client => _client;

  @override
  UserRoleService get userRoleService => _roleService;
}

// L10n нужен реально: ветка «Бот» тянет строку через L10n.of(context).
Widget _wrap(Widget child, liza_matrix.MatrixState state) => MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: const Locale('ru'),
      home: Provider<liza_matrix.MatrixState>.value(
        value: state,
        child: Scaffold(body: child),
      ),
    );

// Фон плашки внутри UserRoleBadge (для проверки «зелёная»).
Color _badgeColor(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(UserRoleBadge),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration! as BoxDecoration).color!;
}

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  Future<void> pumpBadge(WidgetTester tester, String userId, String? roleCode) async {
    final service = UserRoleService(() => client);
    if (roleCode != null) {
      // Каталог отдаёт для роли `ai` label «ИИ» независимо от носителя —
      // повторяем это в тесте, чтобы поймать регресс «взяли role.label».
      service.applyToDeviceEvent(userId, {'code': roleCode, 'label': 'ИИ'});
    }
    final state = _TestMatrixState(client, service);
    await tester.pumpWidget(_wrap(UserRoleBadge(userId: userId), state));
    await tester.pumpAndSettle();
  }

  // AC-1: настоящий AI (liza) → «ИИ», не «Бот». ∀ хоумсерверам
  // (сверка по localpart). AC:RL-bot-ai-badge-real-ai-only/1
  testWidgets('AC-1: настоящий AI (liza) → «ИИ» ∀ хоумсерверам',
      (tester) async {
    const realAi = <String>[
      '@liza:bots.liza.ru',
      '@liza:liza.local',
      '@liza:dev.liza.laba.prodamus.tech',
      '@liza:liza.cyber-agro.ru',
    ];
    for (final userId in realAi) {
      await pumpBadge(tester, userId, 'ai');
      final reason = '$userId → «ИИ»';
      expect(find.text('ИИ'), findsOneWidget, reason: reason);
      expect(find.text('Бот'), findsNothing, reason: reason);
    }
  });

  // AC-2: носитель роли `ai`, НЕ настоящий AI → зелёная «Бот», не «ИИ». ∀ кейсам
  // (квантор «любой аккаунт с ролью ai вне whitelist»). Различаем ИИ/Бот по
  // ТЕКСТУ (оба — Container), плюс проверяем зелёный цвет.
  // AC:RL-bot-ai-badge-real-ai-only/2
  testWidgets('AC-2: role=ai не-AI (@botfather/@support/@cup/newbot/человек) → зелёная «Бот»',
      (tester) async {
    const nonAiBots = <String>[
      '@coolbot:bots.liza.ru', // пользовательский /newbot
      '@botfather:bots.liza.ru',
      // Бывшие ИИ, выведены 2026-11-13: роль ai у остатков → «Бот».
      '@gpt:bots.liza.ru',
      '@deepseek:bots.liza.ru',
      '@support:bots.liza.ru', // продакт: показывать как обычного бота
      '@cup:liza.cyber-agro.ru', // не ходит в OpenRouter
      '@ivan:company.example', // человек с ролью ai вручную
    ];
    for (final userId in nonAiBots) {
      await pumpBadge(tester, userId, 'ai');
      final reason = '$userId → «Бот»';
      expect(find.text('Бот'), findsOneWidget, reason: reason);
      expect(find.text('ИИ'), findsNothing, reason: reason);
      expect(_badgeColor(tester), const Color(0xFF4CAF50), reason: '$reason (зелёная)');
    }
  });

  // AC-3: роль `user` → плашки нет. AC:RL-bot-ai-badge-real-ai-only/3
  testWidgets('AC-3: роль user → плашки нет', (tester) async {
    await pumpBadge(tester, '@ivan:company.example', 'user');
    expect(find.text('ИИ'), findsNothing);
    expect(find.text('Бот'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(UserRoleBadge),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
  });

  // AC-4: роль не загружена (getRole==null) → плашки нет.
  // AC:RL-bot-ai-badge-real-ai-only/4
  testWidgets('AC-4: роль не загружена → плашки нет', (tester) async {
    await pumpBadge(tester, '@nobody:company.example', null);
    expect(find.text('ИИ'), findsNothing);
    expect(find.text('Бот'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(UserRoleBadge),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
  });
}
