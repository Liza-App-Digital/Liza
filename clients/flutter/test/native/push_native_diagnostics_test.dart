import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // ledger:RL-push-native-diagnostics
  // AC:RL-push-native-diagnostics/2
  // AC:RL-push-native-diagnostics/3
  // AC:RL-push-native-diagnostics/4
  // AC:RL-push-native-diagnostics/5
  // AC:RL-push-native-diagnostics/6
  // AC:RL-push-native-diagnostics/10
  // AC:RL-push-native-diagnostics/11
  // AC:RL-push-native-diagnostics/13
  // AC:RL-push-native-diagnostics/8
  // ledger:RL-push-clearing-alert-v2
  // AC:RL-push-clearing-alert-v2/6 — nse_handler.swift: пуш снятия v2
  // AC:RL-push-native-diagnostics/14
  // AC:RL-push-native-diagnostics/15
  // AC:RL-push-native-diagnostics/16
  // AC:RL-push-native-diagnostics/17
  test(
    'production Swift spool и NSE handler на host',
    () async {
      final output = await Directory.systemTemp.createTemp('liza-push-native-');
      try {
        for (final test in [
          'main',
          'nse_handler',
          'delivered_selection',
          'coordinated_io',
        ]) {
          final binary = '${output.path}/$test';
          final compiled = await Process.run('swiftc', [
            'ios/Notification Service Extension/NativePushJournal.swift',
            'ios/Notification Service Extension/PrimaryBadgeSnapshot.swift',
            'ios/Notification Service Extension/DeliveredBanner.swift',
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

  // Структурная проверка подключения, не исполнение callback на iOS/macOS.
  // AC:RL-push-native-diagnostics/17
  test('оба APNs callback используют очередь диагностики токена', () {
    for (final plugin in [
      'ios/Runner/ApnsPushPlugin.swift',
      'macos/Runner/MacApnsPushPlugin.swift',
    ]) {
      final source = File(plugin).readAsStringSync();
      expect(source, contains('NativePushJournal.shared?.enqueueToken(token)'));
      expect(
        source,
        contains(
          'NativePushJournal.shared?.enqueue(.token, reason: .registration_failed)',
        ),
      );
      expect(source, isNot(contains('NativePushJournal.shared?.token(')));
      expect(source, isNot(contains('NativePushJournal.shared?.append(')));
    }
  });
}
