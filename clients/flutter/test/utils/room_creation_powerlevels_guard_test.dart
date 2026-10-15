// ledger:RL-group-permissions-enforcement
// AC:RL-group-permissions-enforcement/9
// AC:RL-group-permissions-enforcement/10
// ledger:RL-space-invite-admin-only
// AC:RL-space-invite-admin-only/1
//
// Source-scan класса «комната создаётся без явного решения о порогах прав».
// Preset private_chat Synapse выставляет invite:0; фикс 25.08 добавил
// groupPowerLevelOverride() только в меню «+», и путь «+» на экране компании
// создавал группу без него (рецидив 2026-10-14). Проверка чистой функции такой
// пропуск не видит — нужен страж на КАЖДЫЙ вызов createRoom/createGroupChat.
//
// Каждый вызов обязан нести override-литерал группы/канала либо стоять в
// allowlist «файл + функция → причина». Устаревшая запись allowlist — тоже
// красный тест: список не должен гнить.
//
// Red-proof: убрать powerLevelContentOverride из create_group_in_space.dart →
// AC-9 перечислит createGroupInSpace; вернуть прямой createGroupChat в
// space_view.dart → упадут AC-9 и AC-10. Вернуть литерал
// `{'events_default': 100}` в create_subspace.dart или new_group.dart
// `_createSpace` → AC-9 перечислит их (пространства теперь не в allowlist,
// RL-space-invite-admin-only AC-1).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _call = RegExp(r'\b(createRoom|createGroupChat)\(');
final _overrideLiteral = RegExp(
  r'powerLevelContentOverride:\s*'
  r'(groupPowerLevelOverride\(\)|channelPowerLevelOverride\(\)|'
  r'spacePowerLevelOverride\()',
);
final _enclosingFn = RegExp(r'(?:Future<.+?>|void)\s+(\w+)\s*\(');

/// Вызовы, которым invite:50 сознательно НЕ навязан. Ключ — `файл#функция`.
const _allowlist = <String, String>{
  'lib/utils/stories/stories_extension.dart#ensureMyStoriesRoom':
      'сторис-комната: доступ раздаёт серверный stories_membership',
  'lib/utils/stories/stories_extension.dart#ensureChannelStoriesRoom':
      'сторис канала: доступ раздаёт серверный stories_membership',
  'lib/pages/chat_details/chat_details.dart#_enableChannelCommentsInner':
      'чат обсуждения канала: модель приглашений — открытый вопрос '
      '(спека 2026-10-14-group-in-space-invite-powerlevel)',
};

/// Текст вызова от `(` до парной `)`, без `//`-комментариев.
String _callText(String src, int openParen) {
  var depth = 0;
  for (var i = openParen; i < src.length; i++) {
    final c = src[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return src.substring(openParen, i + 1);
    }
  }
  throw StateError('несбалансированные скобки после позиции $openParen');
}

String _stripLineComments(String src) => src
    .split('\n')
    .map((l) => l.trimLeft().startsWith('//') ? '' : l)
    .join('\n');

class _Site {
  _Site(this.key, this.text);
  final String key;
  final String text;
}

List<_Site> _scanLib() {
  final sites = <_Site>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\', '/');
    final src = _stripLineComments(entity.readAsStringSync());
    for (final m in _call.allMatches(src)) {
      final before = src.substring(0, m.start);
      final fn = _enclosingFn.allMatches(before).lastOrNull?.group(1) ?? '?';
      sites.add(_Site('$path#$fn', _callText(src, m.end - 1)));
    }
  }
  return sites;
}

void main() {
  test(
    'AC-9: каждый createRoom/createGroupChat в lib/** несёт override-литерал '
    'или стоит в allowlist с причиной',
    () {
      final sites = _scanLib();
      expect(sites, isNotEmpty, reason: 'скан ничего не нашёл — сломан парсер');

      final offenders = [
        for (final s in sites)
          if (!_overrideLiteral.hasMatch(s.text) &&
              !_allowlist.containsKey(s.key))
            s.key,
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'Создание комнаты без явного порога прав: preset private_chat '
            'даст invite:0. Передай groupPowerLevelOverride()/'
            'channelPowerLevelOverride()/spacePowerLevelOverride(...) или '
            'внеси в _allowlist с причиной: '
            '$offenders',
      );

      final siteKeys = sites.map((s) => s.key).toSet();
      final stale = _allowlist.keys
          .where((k) => !siteKeys.contains(k))
          .toList();
      expect(stale, isEmpty, reason: 'устаревшие записи allowlist: $stale');
    },
  );

  test(
    'AC-10: экран компании создаёт группу только через createGroupInSpace',
    () {
      final src = _stripLineComments(
        File('lib/pages/chat_list/space_view.dart').readAsStringSync(),
      );
      expect(src, contains('createGroupInSpace('));
      expect(src, isNot(contains('createGroupChat(')));
    },
  );

  test('парсер берёт многострочный вызов целиком и не видит закомментированный '
      'override', () {
    const src = '''
Future<void> f() async {
  await client.createGroupChat(
    groupName: name(x),
    // powerLevelContentOverride: groupPowerLevelOverride(),
  );
}
''';
    final stripped = _stripLineComments(src);
    final m = _call.firstMatch(stripped)!;
    final text = _callText(stripped, m.end - 1);
    expect(text, contains('groupName: name(x)'));
    expect(_overrideLiteral.hasMatch(text), isFalse);
  });
}
