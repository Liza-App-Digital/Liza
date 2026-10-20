// Страж: macOS-сборка НЕ встраивает расширение уведомлений, iOS — встраивает
// (жалоба Саши 19.10 «поймал задержку пушей», howItWoks/pushes/pushes.md §24).
//
// macOS-NSE не стартует ни на одном Маке: usernoted убивает его за «sluggish
// startup», а через 120 с ПОВТОРНО показывает тот же баннер — уже по
// прочитанному. Механизм нативный, host-тест держит статическую форму
// проекта; что расширение не ищется, проверяется unified log usernoted на
// установленной сборке (manual-пункт реестра).
//
// Target NotificationServiceExtensionMacOS ОСТАЁТСЯ: его читают гейт смены
// Apple-аккаунта (scripts/test-account-regression.sh) и генерация профилей.
//
// ledger:RL-macos-push-no-nse-wakeup
// AC:RL-macos-push-no-nse-wakeup/4

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Тело фазы «Embed App Extensions» (PBXCopyFilesBuildPhase) или пустая
/// строка, если фазы нет.
String _embedPhase(String pbxproj) {
  final match = RegExp(
    r'/\* Embed App Extensions \*/ = \{\s*isa = PBXCopyFilesBuildPhase;(.*?)\n\t\t\};',
    dotAll: true,
  ).firstMatch(pbxproj);
  return match?.group(1) ?? '';
}

void main() {
  final macos = File(
    'macos/Runner.xcodeproj/project.pbxproj',
  ).readAsStringSync();
  final ios = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();

  test('macOS: NSE не встраивается в Liza.app и не собирается вместе с ней', () {
    expect(
      _embedPhase(macos),
      isNot(contains('NotificationServiceExtensionMacOS.appex')),
      reason: 'встроенный appex будится каждым APNs и даёт повтор через 120 с',
    );
    expect(
      RegExp(
        r'PBXTargetDependency \*/ = \{[^}]*NotificationServiceExtensionMacOS',
      ).hasMatch(macos),
      isFalse,
      reason: 'Runner не должен зависеть от сборки macOS-NSE',
    );
  });

  test('macOS: target NSE сохранён для гейта смены Apple-аккаунта', () {
    expect(
      macos,
      contains('/* NotificationServiceExtensionMacOS */ = {\n\t\t\tisa = PBXNativeTarget;'),
    );
  });

  test('iOS: NSE по-прежнему встроен (аватар, бейдж, расшифровка)', () {
    expect(
      _embedPhase(ios),
      contains('Notification Service Extension.appex in Embed App Extensions'),
    );
  });
}
