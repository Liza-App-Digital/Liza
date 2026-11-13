import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // ledger:RL-push-native-diagnostics
  // AC:RL-push-native-diagnostics/2
  // AC:RL-push-native-diagnostics/3
  // AC:RL-push-native-diagnostics/4
  // AC:RL-push-native-diagnostics/5
  // AC:RL-push-native-diagnostics/6
  // AC:RL-push-native-diagnostics/8
  // ledger:RL-push-clearing-alert-v2
  // AC:RL-push-clearing-alert-v2/6 — nse_handler.swift: пуш снятия v2
  test(
    'production Swift spool и NSE handler на host',
    () async {
      final output = await Directory.systemTemp.createTemp('liza-push-native-');
      try {
        for (final test in ['main', 'nse_handler']) {
          final binary = '${output.path}/$test';
          final compiled = await Process.run('swiftc', [
            'ios/Notification Service Extension/NativePushJournal.swift',
            if (test == 'nse_handler') ...[
              'ios/Notification Service Extension/NotificationService.swift',
              'ios/Notification Service Extension/ReadBannerSweep.swift',
            ],
            'test/native/push_diagnostics/$test.swift',
            '-o',
            binary,
          ]);
          expect(
            compiled.exitCode,
            0,
            reason: '${compiled.stdout}\n${compiled.stderr}',
          );
          final executed = await Process.run(binary, []);
          expect(
            executed.exitCode,
            0,
            reason: '${executed.stdout}\n${executed.stderr}',
          );
          expect(executed.stdout, contains('PASS'));
        }
      } finally {
        await output.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
