// ledger:RL-create-menu-order-agent-entry
// ledger:RL-liza-multi-dm-new-request
// AC:RL-liza-multi-dm-new-request/4 — «Новый запрос» первым (AC-1 ниже).
//
// Страж состава и порядка меню «+» шапки списка чатов. guard.render:pure-function —
// `createMenuSections` и есть единственный источник пунктов в ChatListHeader
// (itemBuilder только расставляет разделители, подписи и метку разработчика).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat_list/create_menu_sections.dart';

typedef _A = CreateMenuAction;

// Роль у аккаунта одна; admin+[developer] — admin с доп. ролью developer
// (isCurrentUserDeveloper=true), см. RL-developer-gates-strict.
enum _Role { user, moderator, ai, developer, admin, adminPlusDeveloper }

bool _isDeveloper(_Role r) =>
    r == _Role.developer || r == _Role.adminPlusDeveloper;

void main() {
  // Платформа на состав меню больше не влияет («Контакты» ушли из «+» везде,
  // замечание Надежды 20.10) — перебор ролей полный, платформенного параметра нет.
  List<List<CreateMenuAction>> sections(_Role role) =>
      createMenuSections(isDeveloper: _isDeveloper(role));

  // AC:RL-create-menu-order-agent-entry/1
  test('AC-1: ∀ роль — три раздела в порядке задания 18.10, без «Контактов»', () {
    for (final role in _Role.values) {
      expect(sections(role), [
        [_A.newRequest, _A.group, _A.channel],
        [_A.developers, if (_isDeveloper(role)) _A.mcp],
        [_A.invite],
      ], reason: 'role=$role');
    }
    // История, бот, mini-app, агент и контакты из меню ушли (полоса историй,
    // главное меню BotFather, меню аватара) — проверяем сам enum, а не исходник.
    final names = CreateMenuAction.values.map((a) => a.name).toSet();
    for (final gone in ['story', 'bot', 'miniApp', 'agent', 'contacts']) {
      expect(names.contains(gone), isFalse, reason: gone);
    }
  });

  // AC:RL-create-menu-order-agent-entry/2
  test(
    'AC-2: «Создать канал» есть у всех ролей, канал создаётся приватным',
    () {
      for (final role in _Role.values) {
        expect(
          sections(role).first.contains(_A.channel),
          isTrue,
          reason: 'role=$role',
        );
      }
      // Публичность канала — как у группы: по умолчанию выключена.
      final newGroup = File(
        'lib/pages/new_group/new_group.dart',
      ).readAsStringSync();
      expect(newGroup, contains('bool publicGroup = false;'));
    },
  );

  // AC:RL-create-menu-order-agent-entry/4
  test('AC-4: метку разработчика получает только МСР', () {
    expect(developerOnlyActions, {_A.mcp});
    final header = File(
      'lib/pages/chat_list/chat_list_header.dart',
    ).readAsStringSync();
    expect(header, contains('developerOnlyActions.contains('));
    final label = File(
      'lib/pages/chat_list/create_menu_item_label.dart',
    ).readAsStringSync();
    expect(label, contains('const DeveloperMark()'));
  });

  // AC:RL-create-menu-order-agent-entry/5
  test('AC-5: «Разработчику» — /menu только в существующий DM BotFather', () {
    final src = File(
      'lib/pages/chat_list/chat_list_header.dart',
    ).readAsStringSync();
    final start = src.indexOf('Future<void> _openBotFatherMenu(');
    expect(start, isNot(-1));
    final body = src.substring(start);
    final existingBranch = body.substring(
      body.indexOf('if (existing != null) {'),
      body.indexOf('final created = await showFutureLoadingDialog('),
    );
    final freshBranch = body.substring(
      body.indexOf('final created = await showFutureLoadingDialog('),
    );
    // DM есть → ровно одно /menu; свежий DM → без /menu (карточку BotFather
    // шлёт сам при входе, иначе их было бы две).
    expect("'/menu'".allMatches(existingBranch).length, 1);
    expect(freshBranch.contains('/menu'), isFalse);
    expect(freshBranch, contains('waitForMemberJoin('));
    // Живой DM по member-стейту, а не getDirectChatFromUserId (брошенный DM).
    expect(body, contains('findBotDm(client, _botFatherMxid)'));
    expect(src.contains('getDirectChatFromUserId'), isFalse);
    expect(existingBranch, contains('oopsSomethingWentWrong'));
  });

  // AC:RL-create-menu-order-agent-entry/6
  test('AC-6: tooltip «+» = «Создать», подписи пунктов в ru/en', () {
    Map<String, dynamic> arb(String loc) =>
        jsonDecode(File('lib/l10n/intl_$loc.arb').readAsStringSync())
            as Map<String, dynamic>;
    final ru = arb('ru');
    final en = arb('en');
    expect(ru['create'], 'Создать');
    expect(ru['forDevelopers'], 'Разработчику');
    expect(en['forDevelopers'], 'For developers');
    expect(ru['newLizaRequest'], isA<String>());
    expect(ru['createGroup'], 'Создать группу');
    expect(ru['createChannel'], 'Создать канал');
    expect(ru['inviteContact'], 'Пригласить контакт');
    expect(ru['contactsTitle'], 'Контакты');
    final header = File(
      'lib/pages/chat_list/chat_list_header.dart',
    ).readAsStringSync();
    expect(header, contains('tooltip: L10n.of(context).create,'));
    expect(
      header,
      contains('CreateMenuAction.developers => l10n.forDevelopers'),
    );
  });
}
