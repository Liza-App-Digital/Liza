import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/notification_health.dart';
import 'package:liza/utils/push_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationAuthTracker.resetForTest();
  });

  // ledger:RL-push-native-diagnostics
  // AC:RL-push-native-diagnostics/1
  test('единый single-flight reader; ошибка удаляет старый allowed', () async {
    var calls = 0;
    var fail = false;
    final gate = Completer<Map<Object?, Object?>?>();
    final health = NotificationHealth(
      platform: 'ios',
      readSettings: () {
        calls++;
        if (fail) throw StateError('no native');
        return gate.future;
      },
    );
    final first = health.refresh();
    final second = health.refresh();
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    gate.complete({
      'authorization': 2,
      'timeSensitive': 1,
      'scheduledDelivery': 2,
    });
    final snapshot = await first;
    expect(snapshot.isAllowed, isTrue);
    expect(snapshot.observedAt, isNotNull);
    expect(snapshot.tags['liza.time_sensitive'], 'disabled');
    expect(snapshot.tags['liza.scheduled_delivery'], 'enabled');
    expect(() => snapshot.tags['liza.auth'] = 'denied', throwsUnsupportedError);
    fail = true;
    final failed = await health.refresh();
    expect(failed.isUnknown, isTrue);
    expect(failed.isAllowed, isFalse);
    expect(failed.observedAt, isNull);
    health.dispose();
  });

  test(
    'Android channel/battery и auto-display unknown; settings без permission',
    () async {
      var reads = 0;
      var opens = 0;
      final health = NotificationHealth(
        platform: 'android',
        readSettings: () async {
          reads++;
          return {
            'authorization': 1,
            'channelImportance': -2,
            'batteryOptimization': 1,
            'token': 'POISON_TOKEN',
            'sound': 999,
          };
        },
        openSettings: () async {
          opens++;
          return true;
        },
      );
      final snapshot = await health.refresh();
      expect(snapshot.isDenied, isTrue);
      expect(snapshot.tags['liza.native_auto_display'], 'unknown');
      expect(snapshot.tags['liza.channel_importance'], 'missing');
      expect(snapshot.tags['liza.battery_optimization'], 'optimized');
      expect(snapshot.tags['liza.sound_setting'], 'unknown');
      expect(jsonEncode(snapshot.tags), isNot(contains('POISON_TOKEN')));
      expect(await health.openSettings(), isTrue);
      expect(reads, 1);
      expect(opens, 1);
      health.dispose();
    },
  );

  // AC:RL-push-native-diagnostics/9
  test(
    'реальный native read: loss и отфильтрованные записи дают partial',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final channel = pushReportPlatform() == 'android'
          ? NotificationHealth.androidChannel
          : NotificationHealth.appleChannel;
      Object? response = <Object>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readDiagnosticJournal');
        return response;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await NativePushDiagnostics.readJournal(), isEmpty);
      expect(NativePushDiagnostics.lastReadStatus, 'available');
      response = [
        {
          'id': 'native-diagnostic-loss',
          't': DateTime.now().millisecondsSinceEpoch,
          's': 'diagnosticLoss',
          'reason': 'dropped',
          'value': 1,
        },
      ];
      expect(await NativePushDiagnostics.readJournal(), hasLength(1));
      expect(NativePushDiagnostics.lastReadStatus, 'partial');
      response = [
        {'id': 'invalid', 's': 'POISON_TOKEN'},
      ];
      expect(await NativePushDiagnostics.readJournal(), isEmpty);
      expect(NativePushDiagnostics.lastReadStatus, 'partial');
      response = null;
      expect(await NativePushDiagnostics.readJournal(), isEmpty);
      expect(NativePushDiagnostics.lastReadStatus, 'unknown');
    },
    skip: !const {'ios', 'macos', 'android'}.contains(pushReportPlatform()),
  );

  // AC:RL-push-native-diagnostics/2
  // AC:RL-push-native-diagnostics/4
  test('native schema whitelist, stable dedup, TTL, count, privacy', () {
    final now = DateTime.utc(2026, 10, 30);
    final item = {
      'id': '00000000-0000-0000-0000-000000000001',
      't': now.millisecondsSinceEpoch,
      's': 'nseReceived',
      'event_hash': '0123456789abcdef0123456789abcdef',
      'hash_version': 'POISON_TOKEN',
      'room_id': '!secret:server',
      'token': 'POISON_TOKEN',
    };
    final entries = NativePushDiagnostics.sanitize([
      item,
      item,
      {
        ...item,
        'id': '00000000-0000-0000-0000-000000000002',
        't': now.subtract(const Duration(days: 8)).millisecondsSinceEpoch,
      },
      {
        ...item,
        'id': '00000000-0000-0000-0000-000000000003',
        's': 'POISON_TOKEN',
      },
      {
        ...item,
        'id': '00000000-0000-0000-0000-000000000004',
        't': now.add(const Duration(days: 1)).millisecondsSinceEpoch,
      },
    ], now: now);
    expect(entries, hasLength(1));
    expect(entries.single['id'], '00000000-0000-0000-0000-000000000001');
    expect(entries.single['hash_version'], 'sha256-128');
    expect(jsonEncode(entries), isNot(contains('POISON_TOKEN')));
    expect(jsonEncode(entries), isNot(contains('secret:server')));
    expect(
      NativePushDiagnostics.sanitize(
        List.generate(
          1000,
          (i) => {
            ...item,
            'id':
                '00000000-0000-0000-0000-${i.toRadixString(16).padLeft(12, '0')}',
          },
        ),
        now: now,
      ).length,
      lessThanOrEqualTo(257),
    );
    expect(() => entries.single['id'] = 'changed', throwsUnsupportedError);
  });
  // AC:RL-push-native-diagnostics/10
  test('observable native fields preserve correlation and reject raw data', () {
    final now = DateTime.utc(2026, 11, 16);
    const uuid = '00000000-0000-0000-0000-000000000001';
    const hash = '0123456789abcdef0123456789abcdef';
    final entries = NativePushDiagnostics.sanitize([
      {
        'id': uuid,
        't': now.millisecondsSinceEpoch,
        's': 'removalRequested',
        'event_hash': hash,
        'account_hash': hash,
        'request_hash': hash,
        'run_id': uuid,
        'dispatch_id': uuid,
        'dispatch_attempt': 2,
        'observed_build': '4700',
        'process_role': 'runner',
        'capture_policy': 'async_best_effort',
        'media': 'voice',
        'voice': true,
        'content_shape': 'object',
        'render_source': 'apnsOriginal',
        'render_recipe': 'unknown',
        'source': 'remote',
        'outcome': 'accepted',
        'observed_date': now.millisecondsSinceEpoch - 1000,
        'matched_count': 12,
        'matched_request_hashes': List.filled(12, hash),
        'matches_truncated': true,
        'body': 'PRIVATE_BODY',
        'client_name': 'PRIVATE_ACCOUNT',
      },
    ], now: now);
    expect(entries.single['account_hash'], hash);
    expect(entries.single['request_hash'], hash);
    expect(entries.single['run_id'], uuid);
    expect(entries.single['observed_build'], '4700');
    expect(entries.single['capture_policy'], 'async_best_effort');
    expect(entries.single['render_recipe'], 'unknown');
    expect(entries.single['dispatch_attempt'], 2);
    expect(entries.single['matched_request_hashes'], hasLength(8));
    expect(entries.single['matched_count'], 12);
    expect(entries.single['matches_truncated'], true);
    expect(jsonEncode(entries), isNot(contains('PRIVATE_')));
    final invalid = NativePushDiagnostics.sanitize([
      {
        ...entries.single,
        'account_hash': 'PRIVATE_ACCOUNT',
        'run_id': 'PRIVATE_RUN',
        'observed_build': 'PRIVATE_BUILD',
        'dispatch_attempt': -1,
        'media': 'PRIVATE_FILE',
        'render_recipe': 'PRIVATE_BODY',
      },
    ], now: now);
    expect(jsonEncode(invalid), isNot(contains('PRIVATE_')));
    expect(invalid.single.containsKey('dispatch_attempt'), isFalse);
  });
  // AC:RL-push-native-diagnostics/10
  test('requested presentation masks are bounded and never imply OS output', () {
    final now = DateTime.utc(2026, 11, 16);
    final values = <Object>[0, 1, 2, 26, 65535, -1, 65536, true, 'sound'];
    final entries = NativePushDiagnostics.sanitize([
      for (final value in values.indexed)
        {
          'id':
              '00000000-0000-0000-0000-${value.$1.toString().padLeft(12, '0')}',
          't': now.millisecondsSinceEpoch,
          's': 'presentation',
          'presentation_options': value.$2,
        },
    ], now: now);
    expect(
      entries.map((entry) => entry['presentation_options']).whereType<int>(),
      [0, 1, 2, 26, 65535],
    );
    expect(
      entries
          .skip(5)
          .every((entry) => !entry.containsKey('presentation_options')),
      isTrue,
    );
    expect(
      entries.every(
        (entry) =>
            !entry.containsKey('os_sound') && !entry.containsKey('os_display'),
      ),
      isTrue,
    );
  });
}
