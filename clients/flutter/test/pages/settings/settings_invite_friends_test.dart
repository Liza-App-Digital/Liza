// ledger:RL-settings-invite-friends-action
// AC:RL-settings-invite-friends-action/1 AC:RL-settings-invite-friends-action/2
// AC:RL-settings-invite-friends-action/4
//
// Страж пунктов настроек «Пригласить людей» и «Ваш ID»: l10n-ключи (AC-1, AC-4)
// и вызов shareInvitePeople а не share(mxid) (AC-2 — source-ассерт).
// guard.render: source/l10n ассерт (SettingsView требует SettingsController +
// Matrix + GoRouter; полный рендер — device residual, см. RL).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/pages/settings/settings_view.dart').readAsStringSync();
  });

  // AC-1 (переписан 2026-10-19, Надежда В5 18.10: «не пригласить друзей,
  // заменить на пригласить людей»): пункт использует invitePeople — тот же
  // ключ, что вкладка «Люди»; старого inviteFriends нет ни в lib/, ни в arb.
  // AC:RL-settings-invite-friends-action/1
  test('AC-1: пункт приглашения — invitePeople, inviteFriends удалён', () {
    expect(
      src.contains('L10n.of(context).invitePeople'),
      isTrue,
      reason: 'пункт должен называться «Пригласить людей» (invitePeople)',
    );
    final leftovers = <String>[
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File &&
            (f.path.endsWith('.arb') ||
                (f.path.endsWith('.dart') && !f.path.contains('/l10n/'))) &&
            f.readAsStringSync().contains('inviteFriends'))
          f.path,
    ];
    expect(leftovers, isEmpty, reason: 'inviteFriends остался: $leftovers');
  });

  // AC-2: действие — shareInvitePeople, не LizaShare.share(mxid, copyOnly).
  // Ловит регресс возврата к QR/копирование mxid вместо нативного шеринга.
  // AC:RL-settings-invite-friends-action/2
  test(
    'AC-2: onTap пункта приглашения вызывает shareInvitePeople, '
    'не share(mxid,…) / LizaShare.share',
    () {
      final inviteIdx = src.indexOf('.invitePeople');
      final shareInviteIdx = src.indexOf('LizaShare.shareInvitePeople');
      expect(inviteIdx, isNot(-1), reason: 'invitePeople должен быть');
      expect(
        shareInviteIdx,
        isNot(-1),
        reason: 'shareInvitePeople должен быть в исходнике',
      );
      // Оба находятся в одном ListTile-блоке (расстояние < 200 символов).
      final distance = (shareInviteIdx - inviteIdx).abs();
      expect(
        distance,
        lessThan(200),
        reason: 'shareInvitePeople должен быть рядом с invitePeople '
            '(один ListTile), дистанция: $distance',
      );
    },
  );

  // AC-4 (Надежда, В5 18.10): «не почта, а ваш ID … здесь не собачку, а может
  // быть какой-то человечка». Подпись — settingsYourId, иконка — человечек;
  // пункт по-прежнему ведёт на экран почты (ProdamusID заморожен 14.10).
  // AC:RL-settings-invite-friends-action/4
  test('AC-4: пункт «Ваш ID» — settingsYourId, иконка не «@»', () {
    final idIdx = src.indexOf('L10n.of(context).settingsYourId');
    expect(idIdx, isNot(-1), reason: 'пункта «Ваш ID» нет');
    expect(src.contains('L10n.of(context).settingsEmailTitle'), isFalse);
    expect(src.contains('Icons.alternate_email'), isFalse);
    final tileStart = src.lastIndexOf('ListTile(', idIdx);
    final tile = src.substring(tileStart, src.indexOf('),', idIdx) + 200);
    expect(tile, contains('Icons.person_outline'));
    expect(tile, contains("context.go('/rooms/settings/email')"));

    final ru = File('lib/l10n/intl_ru.arb').readAsStringSync();
    final en = File('lib/l10n/intl_en.arb').readAsStringSync();
    expect(ru, contains('"settingsYourId": "Ваш ID"'));
    expect(en, contains('"settingsYourId": "Your ID"'));
  });
}
