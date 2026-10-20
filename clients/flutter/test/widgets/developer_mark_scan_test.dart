import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Страж реестра регрессии: ledger:RL-developer-mark (см. tests/registry/).
// AC:RL-developer-mark/5 — квантор Надежды «все функции, скрытые за ролью
// разработчика»: каждый файл lib/** с developer-гейтом обязан ставить
// DeveloperMark, иначе новый скрытый пункт тихо появится без метки.

final _gate = RegExp(r'IfDeveloper\(|isCurrentUserDeveloper');

// Гейты, за которыми нет пункта интерфейса (редирект, проверка, сам сервис).
const _notUi = {
  'lib/config/routes.dart',
  'lib/pages/settings/settings.dart',
  'lib/pages/auth_select/auth_select.dart',
  'lib/utils/user_role_service.dart',
  'lib/widgets/matrix.dart',
  'lib/widgets/if_developer.dart',
};

// Места, где метку ставит другая задача «Новый интерфейс 18.10». Задача-владелец
// удаляет свою строку в том же коммите, где ставит метку.
const _pendingByTask = <String, String>{};

void main() {
  test('каждый developer-гейт UI в lib/** ставит DeveloperMark', () {
    final unmarked = <String>[];
    final gated = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.startsWith('lib/l10n/')) continue;
      final src = entity.readAsStringSync();
      if (!_gate.hasMatch(src)) continue;
      gated.add(path);
      if (_notUi.contains(path) || _pendingByTask.containsKey(path)) continue;
      if (!src.contains('DeveloperMark')) unmarked.add(path);
    }
    expect(unmarked, isEmpty, reason: 'гейт без DeveloperMark');
    // Списки не протухают: каждая исключённая строка указывает на живой гейт.
    final stale = {
      ..._notUi,
      ..._pendingByTask.keys,
    }.where((p) => !gated.contains(p)).toList();
    expect(stale, isEmpty, reason: 'в allowlist файл без гейта — убери строку');
  });
}
