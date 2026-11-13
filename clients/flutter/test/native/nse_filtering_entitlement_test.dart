import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // ledger:RL-push-clearing-alert-v2
  // AC:RL-push-clearing-alert-v2/5
  test(
    'filtering entitlement iOS NSE только при LIZA_NSE_FILTERING=1',
    () async {
      final result = await Process.run('bash', [
        'scripts/test-nse-filtering-entitlement.sh',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('OK: filtering entitlement за флагом'));
    },
    skip: !Platform.isMacOS,
  );
}
