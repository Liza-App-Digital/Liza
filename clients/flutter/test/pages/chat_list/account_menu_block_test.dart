import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat_list/client_chooser_button.dart';

// Страж реестра регрессии: ledger:RL-account-menu-single-account (см. tests/registry/).
// Задание Надежды 18.10 (В4): «Карандаш стоит убрать. … Если аккаунт
// один-единственный, не показывать блок аккаунта».

const _menuPath = 'lib/pages/chat_list/client_chooser_button.dart';

void main() {
  group('accountMenuBlock', () {
    // AC:RL-account-menu-single-account/1
    for (final loggedIn in [1, 2, 3]) {
      for (final canAdd in [false, true]) {
        test('вошедших $loggedIn, «Добавить аккаунт» $canAdd', () {
          final block = accountMenuBlock(
            loggedInClients: loggedIn,
            canAddAccount: canAdd,
          );
          expect(block.accounts, loggedIn >= 2);
          expect(block.divider, loggedIn >= 2 || canAdd);
        });
      }
    }
  });

  // AC:RL-account-menu-single-account/2 — карандаша правки пакетов в меню
  // аватара нет. Попап-роут host-тестом без ChatListController не поднять,
  // поэтому сверяем исходник меню.
  test('в меню аватара нет карандаша и правки пакетов', () {
    final src = File(_menuPath).readAsStringSync();
    expect(src, isNot(contains('Icons.edit_outlined')));
    expect(src, isNot(contains('editBundlesForAccount')));
  });

  // AC:RL-account-menu-single-account/5 — «Приложения» и «Добавить аккаунт»
  // видны только developer и несут метку «Р».
  test('«Приложения» и «Добавить аккаунт» с DeveloperMark', () {
    final src = File(_menuPath).readAsStringSync();
    for (final label in ['miniAppCatalogTitle', 'addAccount)']) {
      final at = src.indexOf(label);
      expect(at, isNonNegative, reason: label);
      final row = src.substring(at, src.indexOf('],', at));
      expect(row, contains('const DeveloperMark()'), reason: label);
    }
  });
}
