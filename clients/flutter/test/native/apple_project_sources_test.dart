import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // ledger:RL-push-causal-contract
  // AC:RL-push-causal-contract/10
  for (final platform in ['ios', 'macos']) {
    test('$platform: объекты Xcode имеют уникальные идентификаторы', () {
      final project = File(
        '$platform/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      final definitions = RegExp(
        r'^\s*([A-F0-9]{24}) /\* [^\n]*? \*/ = \{',
        multiLine: true,
      ).allMatches(project);
      final counts = <String, int>{};
      for (final definition in definitions) {
        final id = definition.group(1)!;
        counts.update(id, (count) => count + 1, ifAbsent: () => 1);
      }
      expect(counts, isNotEmpty);
      expect(
        counts.entries.where((entry) => entry.value > 1),
        isEmpty,
        reason: 'Повторный ID перезаписывает Swift-файл в проекте Xcode',
      );
    });
  }
}
