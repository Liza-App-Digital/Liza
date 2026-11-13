import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // ledger:RL-push-read-banner-sweep
  // AC:RL-push-read-banner-sweep/1
  // AC:RL-push-read-banner-sweep/2
  // AC:RL-push-read-banner-sweep/3
  // AC:RL-push-read-banner-sweep/17
  test(
    'ReadBannerSweep: read=true из /notifications, токен по client_name, фильтр владельца',
    () async {
      final output = await Directory.systemTemp.createTemp('liza-read-sweep-');
      try {
        final binary = '${output.path}/sweep';
        final compiled = await Process.run('swiftc', [
          'ios/Notification Service Extension/ReadBannerSweep.swift',
          'test/native/read_banner_sweep/sweep_logic.swift',
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
        expect(executed.stdout, contains('ReadBannerSweep PASS'));
      } finally {
        await output.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
