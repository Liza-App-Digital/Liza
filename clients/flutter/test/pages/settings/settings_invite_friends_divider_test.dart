// Страж сепаратора перед блоком параметров аккаунта в настройках.
//
// «Пригласить людей» — разовое действие наружу, а идущие следом «Ваш ID» и
// «Никнейм» — параметры аккаунта. Без разделителя все три пункта читались
// одним списком.
//
// guard.render: source-ассерт. SettingsView требует SettingsController +
// Matrix + GoRouter, полный рендер на хосте недоступен — тот же приём и та же
// оговорка, что в settings_invite_friends_test.dart рядом.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/pages/settings/settings_view.dart').readAsStringSync();
  });

  test(
    'между «Пригласить людей» и «Ваш ID» стоит Divider',
    () {
      final inviteIdx = src.indexOf('.invitePeople');
      final emailIdx = src.indexOf('.settingsYourId');
      expect(inviteIdx, isNot(-1), reason: 'пункт invitePeople должен быть');
      expect(emailIdx, isNot(-1), reason: 'пункт settingsYourId должен быть');
      expect(
        inviteIdx < emailIdx,
        isTrue,
        reason: 'порядок пунктов: сначала приглашение, потом почта',
      );

      final between = src.substring(inviteIdx, emailIdx);
      expect(
        between.contains('Divider(color: theme.dividerColor)'),
        isTrue,
        reason: 'между приглашением и почтой должен стоять '
            'Divider(color: theme.dividerColor) — в стиле остальных '
            'разделителей этого экрана',
      );
    },
  );

  test(
    'сепаратор оформлен как остальные на экране (без height/indent)',
    () {
      // Ловит расхождение стиля: если новый разделитель получит свои отступы,
      // он визуально выпадет из списка.
      expect(
        src.contains('Divider(color: theme.dividerColor, height:'),
        isFalse,
        reason: 'разделители этого экрана однострочные, без height/indent',
      );
    },
  );
}
