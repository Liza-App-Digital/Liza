// ledger:RL-create-menu-contacts-items
// AC:RL-create-menu-contacts-items/3 AC:RL-create-menu-contacts-items/4
//
// Страж enum-пунктов меню «+» и маршрутизации invite.
// guard.render:pure-function — не рендерит ChatListHeader (требует
// ChatListController + Matrix; device residual для AC-1/2, см. RL).
// AC-4: состав enum по CreateMenuAction.values (позитив и негатив).
// AC-3: invite-ветка вызывает shareInvitePeople, не QR-метод.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat_list/create_menu_sections.dart';

void main() {
  late String src;

  setUpAll(() {
    // Путь относительно flutter/ (flutter test запускается из flutter/).
    src = File('lib/pages/chat_list/chat_list_header.dart').readAsStringSync();
  });

  // AC-4: состав enum — по самим значениям (src.contains('story') был бы
  // ложно-зелёным: слово встречается в комментариях и других идентификаторах).
  // AC:RL-create-menu-contacts-items/4
  test('AC-4: CreateMenuAction.values — актуальный состав меню 18.10', () {
    final names = CreateMenuAction.values.map((a) => a.name).toSet();
    for (final value in [
      'newRequest',
      'group',
      'channel',
      'developers',
      'mcp',
      'invite',
      'contacts',
    ]) {
      expect(names.contains(value), isTrue, reason: value);
    }
    for (final gone in ['story', 'bot', 'miniApp', 'agent']) {
      expect(names.contains(gone), isFalse, reason: gone);
    }
  });

  // Витрина MCP: все ТРИ входа («+», настройки, «⋮» в чате с Лизой) ведут по
  // ОБЩЕЙ константе AppRoutes.mcp, а не по литералу пути.
  // AC:RL-mcp-showcase-entry-points/5
  test(
    'AC-5: пункт mcp есть в enum, три входа ведут по AppRoutes.mcp',
    () {
      expect(
        src.contains('mcp'),
        isTrue,
        reason: 'enum _CreateMenuAction должен содержать значение mcp',
      );
      for (final path in [
        'lib/pages/chat_list/chat_list_header.dart',
        'lib/pages/settings/settings_view.dart',
        'lib/widgets/chat_settings_popup_menu.dart',
      ]) {
        final entry = File(path).readAsStringSync();
        expect(
          entry.contains('context.go(AppRoutes.mcp)'),
          isTrue,
          reason:
              '$path: вход в витрину обязан идти по общей константе '
              'AppRoutes.mcp — три литерала пути разъедутся молча',
        );
        expect(
          RegExp(r"""context\.go\(['"]/rooms/(settings/integrations|mcp)""")
              .hasMatch(entry),
          isFalse,
          reason: '$path: литерал пути вместо константы — тот самый разъезд',
        );
      }
    },
  );

  // AC-3: invite-ветка → shareInvitePeople (не QR / не LizaShare.share(mxid,…)).
  // AC:RL-create-menu-contacts-items/3
  test(
    'AC-3: ветка invite вызывает LizaShare.shareInvitePeople, '
    'contacts → /rooms/contacts',
    () {
      expect(
        src.contains('CreateMenuAction.invite'),
        isTrue,
        reason: 'enum-значение invite должно быть в switch',
      );
      expect(
        src.contains('LizaShare.shareInvitePeople'),
        isTrue,
        reason: 'invite-ветка должна вызывать shareInvitePeople, не share(mxid)',
      );
      expect(
        src.contains("context.go('/rooms/contacts')"),
        isTrue,
        reason: "contacts-ветка должна вести на '/rooms/contacts'",
      );
    },
  );
}
