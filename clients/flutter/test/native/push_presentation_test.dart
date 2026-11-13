import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // ledger:RL-push-clearing-alert-v2
  // AC:RL-push-clearing-alert-v2/7
  test(
    'AppDelegate.willPresent: пуш снятия v2 на переднем плане не показывается, '
    'сообщения — как раньше',
    () async {
      final output = await Directory.systemTemp.createTemp(
        'liza-presentation-',
      );
      try {
        final binary = '${output.path}/presentation';
        final compiled = await Process.run('swiftc', [
          '-parse-as-library',
          'ios/Runner/PushPresentation.swift',
          'test/native/push_presentation/main.swift',
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
        expect(executed.stdout, contains('PushPresentation PASS'));
      } finally {
        await output.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('AppDelegate.willPresent решает через PushPresentation.decide', () {
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(delegate, contains('PushPresentation.decide('));
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(project, contains('PushPresentation.swift in Sources'));
  });
}
