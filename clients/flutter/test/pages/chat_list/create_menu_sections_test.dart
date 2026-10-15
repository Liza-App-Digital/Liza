// ledger:RL-create-menu-order-agent-entry
// ledger:RL-liza-multi-dm-new-request
// AC:RL-liza-multi-dm-new-request/4 — «Новый запрос» первым (AC-1 ниже).
//
// Страж состава и порядка меню «+» шапки списка чатов. guard.render:pure-function —
// `createMenuSections` и есть единственный источник пунктов в ChatListHeader
// (itemBuilder только расставляет разделители между разделами и подписи).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat_list/create_menu_sections.dart';

typedef _A = CreateMenuAction;

enum _Role { user, admin, developer }

void main() {
  List<List<CreateMenuAction>> sections(_Role role, bool mobile) =>
      createMenuSections(
        isAdmin: role == _Role.admin,
        isDeveloper: role == _Role.developer,
        isMobile: mobile,
      );

  final cases = [
    for (final role in _Role.values)
      for (final mobile in [true, false]) (role, mobile),
  ];

  // AC:RL-create-menu-order-agent-entry/1
  test('AC-1: ∀ роль × платформа — порядок разделов как в постановке', () {
    for (final (role, mobile) in cases) {
      final s = sections(role, mobile);
      final reason = 'role=$role mobile=$mobile';
      expect(s.first, [
        _A.newRequest,
        _A.group,
        if (role == _Role.admin) _A.channel,
        _A.story,
        _A.bot,
        _A.miniApp,
        _A.agent,
      ], reason: reason);
      expect(s.last, [_A.invite, if (mobile) _A.contacts], reason: reason);
      expect(s.every((section) => section.isNotEmpty), isTrue, reason: reason);
    }
  });

  // AC:RL-create-menu-order-agent-entry/2
  test('AC-2: «Создать канал» только у admin', () {
    for (final (role, mobile) in cases) {
      expect(
        sections(role, mobile).expand((e) => e).contains(_A.channel),
        role == _Role.admin,
        reason: 'role=$role mobile=$mobile',
      );
    }
  });

  // AC:RL-create-menu-order-agent-entry/3
  test('AC-3: МСР отдельным разделом только у developer/admin, иначе без '
      'лишнего раздела', () {
    for (final (role, mobile) in cases) {
      final s = sections(role, mobile);
      final privileged = role != _Role.user;
      expect(s.length, privileged ? 3 : 2, reason: 'role=$role');
      expect(
        s.expand((e) => e).contains(_A.mcp),
        privileged,
        reason: 'role=$role mobile=$mobile',
      );
      if (privileged) expect(s[1], [_A.mcp]);
    }
  });

  // AC:RL-create-menu-order-agent-entry/4
  test('AC-4: «Контакты» только на мобильных', () {
    for (final (role, mobile) in cases) {
      expect(
        sections(role, mobile).expand((e) => e).contains(_A.contacts),
        mobile,
        reason: 'role=$role mobile=$mobile',
      );
    }
  });

  // AC:RL-create-menu-order-agent-entry/5
  test('AC-5: тексты пунктов в ru и ключ агента в en', () {
    Map<String, dynamic> arb(String loc) =>
        jsonDecode(File('lib/l10n/intl_$loc.arb').readAsStringSync())
            as Map<String, dynamic>;
    final ru = arb('ru');
    final en = arb('en');
    expect(ru['createGroup'], 'Создать группу');
    expect(ru['createChannel'], 'Создать канал');
    expect(ru['createStory'], 'Создать историю');
    expect(ru['createBot'], 'Создать бота');
    expect(ru['createMiniApp'], 'Создать mini-app');
    expect(ru['connectAiAgent'], 'Подключить ИИ-агента');
    expect(ru['inviteContact'], 'Пригласить контакт');
    expect(ru['contactsTitle'], 'Контакты');
    expect(en['connectAiAgent'], isA<String>());
  });

  // AC:RL-create-menu-order-agent-entry/6
  test('AC-6: пункт агента шлёт Лизе callback agent.start, а не текст', () {
    final src = File(
      'lib/pages/chat_list/chat_list_header.dart',
    ).readAsStringSync();
    expect(src, contains('CreateMenuAction.channel => l10n.createChannel'));
    expect(src, contains('findLizaAssistantDm(client, lizaMxid)'));
    expect(src, contains('MatrixState.lizaMxid'));
    expect(src, contains("'msgtype': 'com.liza.miniapp.callback'"));
    expect(src, contains("'button_id': 'agent.start'"));
    expect(
      src.contains('sendTextEvent'),
      isFalse,
      reason: 'текст-фраза на шаге «название» стала бы названием чата агента',
    );
  });
}
