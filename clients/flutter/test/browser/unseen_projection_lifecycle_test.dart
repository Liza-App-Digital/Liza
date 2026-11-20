@TestOn('browser')
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/app_badge.dart';

import '../widgets/unseen_projection_lifecycle_test.dart' as scenario;

// Те же assertions настоящего Matrix, но только в Chrome/IndexedDB.
// Metadata запрещает ошибочно посчитать VM discovery браузерным покрытием.
void main() {
  if (!kIsWeb) throw StateError('Этот набор требует настоящего браузера');
  // AC:RL-edited-message-read-cursor/27
  test(
    'web native badge не обращается к Platform и не выдаёт applied stamp',
    () async {
      final before = AppBadge.writeSeq;
      await AppBadge.trySet(1);
      await AppBadge.trySet(0);
      expect(AppBadge.writeSeq, before);
    },
  );
  group('настоящий Chrome/IndexedDB', scenario.main);
}
