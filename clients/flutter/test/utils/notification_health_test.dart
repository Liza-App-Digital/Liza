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
}
