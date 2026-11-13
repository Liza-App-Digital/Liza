// ledger:RL-miniapp-capsules-microphone
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat/mini_app_permissions.dart';

void main() {
  const capsulesUrl = 'https://platform.capsule.laba.pro/';
  final capsulesOrigin = Uri.parse('https://platform.capsule.laba.pro');
  final mic = PermissionResourceType.MICROPHONE;
  final camera = PermissionResourceType.CAMERA;

  PermissionResponseAction decide({
    String appId = capsulesMiniAppId,
    String appType = 'first_party',
    String appUrl = capsulesUrl,
    Uri? origin,
    required List<PermissionResourceType> resources,
  }) => miniAppPermissionDecision(
    appId: appId,
    appType: appType,
    appUrl: appUrl,
    requestOrigin: origin ?? capsulesOrigin,
    resources: resources,
  );

  test('капсулы + MICROPHONE → GRANT  AC:RL-miniapp-capsules-microphone/1', () {
    expect(decide(resources: [mic]), PermissionResponseAction.GRANT);
  });

  test('капсулы: всё, кроме одного микрофона, → DENY  '
      'AC:RL-miniapp-capsules-microphone/2', () {
    expect(decide(resources: [camera]), PermissionResponseAction.DENY);
    expect(decide(resources: [mic, camera]), PermissionResponseAction.DENY);
    expect(
      decide(resources: [PermissionResourceType.GEOLOCATION]),
      PermissionResponseAction.DENY,
    );
    expect(decide(resources: []), PermissionResponseAction.DENY);
  });

  test('другой мини-апп → DENY  AC:RL-miniapp-capsules-microphone/3', () {
    expect(
      decide(appId: 'weather', resources: [mic]),
      PermissionResponseAction.DENY,
    );
  });

  test('third_party (даже с app_id капсул) → DENY  '
      'AC:RL-miniapp-capsules-microphone/4', () {
    expect(
      decide(appType: 'third_party', resources: [mic]),
      PermissionResponseAction.DENY,
    );
    expect(
      decide(appId: 'weather', appType: 'third_party', resources: [mic]),
      PermissionResponseAction.DENY,
    );
  });

  test('страница ушла на чужой origin → DENY  '
      'AC:RL-miniapp-capsules-microphone/5', () {
    expect(
      decide(origin: Uri.parse('https://evil.example'), resources: [mic]),
      PermissionResponseAction.DENY,
    );
    expect(
      decide(
        origin: Uri.parse('http://platform.capsule.laba.pro'),
        resources: [mic],
      ),
      PermissionResponseAction.DENY,
    );
  });

  test('флаг iframe allow="microphone" — только капсулам first_party', () {
    expect(
      miniAppMayUseMicrophone(appId: capsulesMiniAppId, appType: 'first_party'),
      isTrue,
    );
    expect(
      miniAppMayUseMicrophone(appId: capsulesMiniAppId, appType: 'third_party'),
      isFalse,
    );
    expect(
      miniAppMayUseMicrophone(appId: 'weather', appType: 'first_party'),
      isFalse,
    );
  });
}
