// ledger:RL-push-clearing-alert-v2

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/background_push.dart';
import 'package:liza/utils/push_helper.dart';

void main() {
  Object? capability({
    required bool apple,
    String? platform,
    required bool nseFiltering,
  }) =>
      (BackgroundPush.pusherAdditionalProperties(
            'Liza $platform',
            dataMessage: platform ?? 'x',
            apple: apple,
            platform: platform,
            nseFiltering: nseFiltering,
          )['default_payload']
          as Map)[pushClearCapabilityKey];

  // AC:RL-push-clearing-alert-v2/4
  test('liza_clear_v=2 только iOS-сборке с filtering entitlement', () {
    expect(capability(apple: true, platform: 'ios', nseFiltering: true), 2);
    expect(capability(apple: true, platform: 'ios', nseFiltering: false), 1);
    // macOS ключа не получает: v2 — только iOS.
    expect(capability(apple: true, platform: 'macos', nseFiltering: true), 1);
    expect(
      capability(apple: false, platform: 'android', nseFiltering: true),
      isNull,
    );
  });

  // AC:RL-push-clearing-alert-v2/4
  test('флаг сборки по умолчанию выключен', () {
    expect(nseFilteringEnabled, isFalse);
  });
}
