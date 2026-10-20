// ledger:RL-settings-privacy-security-labels
// AC:RL-settings-privacy-security-labels/1
// AC:RL-settings-privacy-security-labels/3 AC:RL-settings-privacy-security-labels/4
// AC:RL-settings-privacy-security-labels/5
//
// Страж подписей пунктов настроек (LABA-2548): экран внутренних настроек —
// «Приватность» (с 2026-10-19, задача 07: вход возвращён перед «Сеансами»);
// внешней ссылки на политику конфиденциальности в меню нет (с 2026-09-25 она
// только в «О приложении»).
// guard.render: source/l10n-ассерты — полный рендер SettingsView требует
// SettingsController + Matrix + GoRouter (тот же компромисс, что и в
// settings_invite_friends_test.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String settingsSrc;
  late String securitySrc;
  late String enArb;
  late String ruArb;

  setUpAll(() {
    settingsSrc = File(
      'lib/pages/settings/settings_view.dart',
    ).readAsStringSync();
    securitySrc = File(
      'lib/pages/settings_security/settings_security_view.dart',
    ).readAsStringSync();
    enArb = File('lib/l10n/intl_en.arb').readAsStringSync();
    ruArb = File('lib/l10n/intl_ru.arb').readAsStringSync();
  });

  // AC-1 (переформулирован 2026-09-25): пункт «Политика конфиденциальности»
  // убран из меню «Настройки» — документ доступен в «О приложении» (там его
  // держит AC-3 RL-about-screen-legal).
  // AC:RL-settings-privacy-security-labels/1
  test('AC-1: в меню настроек нет пункта launchUrl(privacyUrl)', () {
    expect(
      settingsSrc.contains('AppConfig.privacyUrl'),
      isFalse,
      reason:
          'политика конфиденциальности — только в «О приложении», '
          'дубль в меню настроек убран',
    );
    expect(settingsSrc.contains('.privacyPolicy'), isFalse);
  });

  // AC-3 (переформулирован 2026-10-19, задача 07): пункт «Приватность» есть,
  // ведёт на /rooms/settings/security и стоит СТРОГО перед «Сеансами»
  // (Надежда, В5 18.10: «сюда до сеансов»). Без него «Удалить аккаунт»
  // недоступен из интерфейса — App Store 5.1.1(v).
  // AC:RL-settings-privacy-security-labels/3
  test('AC-3: пункт «Приватность» ведёт на security и стоит перед «Сеансами»',
      () {
    final privacyIdx = settingsSrc.indexOf('L10n.of(context).privacy)');
    final routeIdx = settingsSrc.indexOf(
      "context.go('/rooms/settings/security')",
    );
    final devicesIdx = settingsSrc.indexOf('L10n.of(context).devices)');
    expect(privacyIdx, isNot(-1), reason: 'пункта «Приватность» нет в меню');
    expect(routeIdx, isNot(-1), reason: 'нет входа в /rooms/settings/security');
    expect(devicesIdx, isNot(-1));
    expect(
      routeIdx > privacyIdx && routeIdx < devicesIdx,
      isTrue,
      reason: 'переход на security должен принадлежать пункту «Приватность»',
    );
    expect(
      privacyIdx < devicesIdx,
      isTrue,
      reason: '«Приватность» — строго перед «Сеансами»',
    );
  });

  // AC-4 (переформулирован 2026-10-19): AppBar экрана — тот же ключ privacy,
  // что и пункт меню; старого privacyAndSecurity в коде и arb нет.
  // AC:RL-settings-privacy-security-labels/4
  test('AC-4: AppBar settings_security_view = privacy, privacyAndSecurity нет',
      () {
    final appBarIdx = securitySrc.indexOf('appBar: AppBar(');
    expect(appBarIdx, isNot(-1));
    final head = securitySrc.substring(appBarIdx, appBarIdx + 200);
    expect(
      head.contains('L10n.of(context).privacy)'),
      isTrue,
      reason: 'заголовок экрана обязан совпадать с подписью пункта меню',
    );
    for (final dir in [Directory('lib/pages'), Directory('lib/widgets')]) {
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        expect(
          f.readAsStringSync().contains('privacyAndSecurity'),
          isFalse,
          reason: '${f.path}: ключ privacyAndSecurity удалён',
        );
      }
    }
    expect(enArb.contains('"privacyAndSecurity"'), isFalse);
    expect(ruArb.contains('"privacyAndSecurity"'), isFalse);
  });

  // AC-5: русская подпись «Приватность» есть в intl_ru.arb дословно.
  // Отсутствие ключа в intl_en.arb ловит кодогенерация gen_l10n раньше теста;
  // молчаливо ломается только ru (английский fallback в русском UI).
  // AC:RL-settings-privacy-security-labels/5
  test('AC-5: intl_ru.arb содержит "privacy": "Приватность"', () {
    expect(
      ruArb.contains('"privacy": "Приватность"'),
      isTrue,
      reason: 'без русского значения UI покажет английский Privacy',
    );
  });
}
