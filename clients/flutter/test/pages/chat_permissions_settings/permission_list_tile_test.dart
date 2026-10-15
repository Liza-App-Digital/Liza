import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_permissions_settings/permission_list_tile.dart';
import 'package:liza/utils/chat_topology.dart';

Widget _wrap(Widget child) => MaterialApp(
  locale: const Locale('ru'),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  group('PowerLevelPreset.fromMatrixLevel', () {
    test('нормализует произвольный Matrix-уровень до одной из трёх ролей', () {
      expect(PowerLevelPreset.fromMatrixLevel(0), PowerLevelPreset.user);
      expect(PowerLevelPreset.fromMatrixLevel(49), PowerLevelPreset.user);
      expect(PowerLevelPreset.fromMatrixLevel(50), PowerLevelPreset.moderator);
      expect(PowerLevelPreset.fromMatrixLevel(98), PowerLevelPreset.moderator);
      // С 2026-10-14 админ = 99 (владелец 100): порог 99 — «Администратор»,
      // старые пороги 100 показываются тем же пресетом (RL-room-owner-transfer).
      expect(PowerLevelPreset.fromMatrixLevel(99), PowerLevelPreset.admin);
      expect(PowerLevelPreset.fromMatrixLevel(100), PowerLevelPreset.admin);
      expect(PowerLevelPreset.admin.level, 99);
    });
  });

  // ledger:RL-room-owner-transfer — AC-12: «Права по умолчанию» (users_default)
  // нельзя поднять до «Администратор» ни админу, ни владельцу — иначе админами
  // становятся все участники. Реальный экранный виджет + реальный потолок.
  for (final own in [ownerPowerLevel, adminPowerLevel]) {
    testWidgets('AC:RL-room-owner-transfer/12 own=$own: users_default не '
        'предлагает «Администратор», прочий порог — предлагает', (
      tester,
    ) async {
      final chosen = <int?>[];
      Widget tile(String key) => PermissionsListTile(
        permissionKey: key,
        permission: 0,
        canEdit: true,
        maxLevel: permissionThresholdMaxLevel(key: key, ownPowerLevel: own),
        onChanged: chosen.add,
      );

      await tester.pumpWidget(_wrap(tile('users_default')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<PowerLevelPreset>));
      await tester.pumpAndSettle();
      expect(find.text('Администратор'), findsNothing);
      expect(find.text('Модератор'), findsOneWidget);
      await tester.tap(find.text('Модератор'));
      await tester.pumpAndSettle();
      expect(chosen, [moderatorPowerLevel]);

      await tester.pumpWidget(_wrap(tile('kick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<PowerLevelPreset>));
      await tester.pumpAndSettle();
      expect(find.text('Администратор'), findsOneWidget);
    });
  }

  testWidgets('текущее значение выше потолка остаётся видимым '
      '(уже выданный users_default=99 не ломает dropdown)', (tester) async {
    await tester.pumpWidget(
      _wrap(
        PermissionsListTile(
          permissionKey: 'users_default',
          permission: 99,
          canEdit: true,
          maxLevel: moderatorPowerLevel,
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Администратор'), findsOneWidget);
  });
}
