// Телеметрия разрешения на уведомления: ответ системы на запрос, переходы
// статуса, экран блокировки. Спека
// `docs/superpowers/specs/2026-10-28-push-auth-request-telemetry-design.md`.
//
// ledger:RL-push-auth-request-telemetry
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/apns_push_service.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/push_journal.dart';

const _channel = MethodChannel('com.prodamus.laba.liza/apns');

List<PushJournalEntry> _stage(PushJournal j, PushStage s) =>
    j.entries.where((e) => e.stage == s).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationAuthTracker.resetForTest();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  // AC:RL-push-auth-request-telemetry/1
  group('разбор ответа натива', () {
    test('старый натив (bool) — granted без статусов', () {
      final r = AuthRequestResult.parse(true);
      expect(r.granted, isTrue);
      expect(r.before, isNull);
      expect(r.outcome, PushReason.authGranted);
      expect(AuthRequestResult.parse(false).outcome, PushReason.authRefused);
      expect(AuthRequestResult.parse(null).outcome, PushReason.authRefused);
    });

    test('словарь: статусы, ошибка, активность', () {
      final r = AuthRequestResult.parse({
        'granted': false,
        'before': 1,
        'after': 1,
        'errorDomain': 'UNErrorDomain',
        'errorCode': 1,
        'active': false,
        'hasWindow': false,
      }, elapsedMs: 7);
      expect(r.before, 1);
      expect(r.after, 1);
      expect(r.outcome, PushReason.authError);
      expect(r.errorTag, 'UNErrorDomain:1');
      expect(r.active, isFalse);
      expect(r.hasWindow, isFalse);
      expect(r.elapsedMs, 7);
    });

    test(
      'домен ошибки не похож на константу → other (текст в тег не идёт)',
      () {
        final r = AuthRequestResult.parse({
          'granted': false,
          'errorDomain': '/Users/someone/Library error',
          'errorCode': 3,
        });
        expect(r.errorTag, 'other:3');
      },
    );
  });

  // AC:RL-push-auth-request-telemetry/2
  test(
    'переход статуса пишется ровно один раз на смену; первый — с v=-1',
    () async {
      final j = PushJournal.forTest();
      for (final s in [1, 1, 2, 2, 1]) {
        await NotificationAuthTracker.observe(s, journal: j);
      }
      final changes = _stage(j, PushStage.authStatus);
      expect(changes.map((e) => (e.reason, e.value)).toList(), [
        (PushReason.authDenied, -1),
        (PushReason.authAuthorized, 1),
        (PushReason.authDenied, 2),
      ]);
    },
  );

  // AC:RL-push-auth-request-telemetry/2
  test('параллельные чтения одного статуса не дают двух записей', () async {
    final j = PushJournal.forTest();
    await Future.wait([
      NotificationAuthTracker.observe(2, journal: j),
      NotificationAuthTracker.observe(2, journal: j),
      NotificationAuthTracker.observe(2, journal: j),
    ]);
    expect(_stage(j, PushStage.authStatus), hasLength(1));
  });

  // AC:RL-push-auth-request-telemetry/3
  test(
    'переход ловится через перезапуск; первый статус и сессия — навсегда',
    () async {
      final j = PushJournal.forTest();
      await NotificationAuthTracker.observe(1, journal: j, hasSession: false);
      NotificationAuthTracker.resetForTest(); // «перезапуск» процесса
      await NotificationAuthTracker.observe(
        2,
        journal: j,
        hasSession: true,
        now: DateTime.now().add(const Duration(hours: 2)),
      );
      final changes = _stage(j, PushStage.authStatus);
      expect(changes.last.reason, PushReason.authAuthorized);
      expect(changes.last.value, 1);
      final tags = await NotificationAuthTracker.reportTags();
      expect(tags['liza.auth_first'], 'denied');
      expect(tags['liza.auth_first_session'], 'logged_out');
      expect(tags['liza.auth_change'], 'denied>authorized');
      expect(
        int.parse(tags['liza.auth_change_gap_s']!),
        greaterThanOrEqualTo(7190),
      );
    },
  );

  test('null-статус (нет плагина) не пишется и не затирает прошлый', () async {
    final j = PushJournal.forTest();
    await NotificationAuthTracker.observe(2, journal: j);
    await NotificationAuthTracker.observe(null, journal: j);
    await NotificationAuthTracker.observe(2, journal: j);
    expect(_stage(j, PushStage.authStatus), hasLength(1));
  });

  // AC:RL-push-auth-request-telemetry/4
  test(
    'запрос: одинаковые ответы — одна запись; первый настоящий запрос запомнен',
    () async {
      final j = PushJournal.forTest();
      const prompt = AuthRequestResult(
        granted: false,
        before: 0,
        after: 1,
        elapsedMs: 40,
      );
      const repeat = AuthRequestResult(
        granted: false,
        before: 1,
        after: 1,
        elapsedMs: 2,
      );
      await NotificationAuthTracker.noteRequest(
        prompt,
        source: AuthRequestSource.fln,
        journal: j,
      );
      for (var i = 0; i < 5; i++) {
        await NotificationAuthTracker.noteRequest(
          repeat,
          source: AuthRequestSource.setupFirebase,
          journal: j,
        );
      }
      await Future<void>.delayed(Duration.zero);
      final reqs = _stage(j, PushStage.authRequest);
      expect(reqs.map((e) => (e.reason, e.value)).toList(), [
        (PushReason.authRefused, 0),
        (PushReason.authRefused, 1),
      ]);
      final tags = await NotificationAuthTracker.reportTags();
      expect(tags['liza.auth_prompt'], 'authRefused');
      expect(tags['liza.auth_prompt_source'], 'fln');
      expect(tags['liza.auth_prompt_ms'], '40');
      expect(tags['liza.auth_req_source'], 'setupFirebase');
      expect(tags['liza.auth_req_before'], 'denied');
    },
  );

  // AC:RL-push-auth-request-telemetry/5
  test(
    'все теги трекера и экран блокировки проходят словарь push-report ≤ 32',
    () async {
      await NotificationAuthTracker.observe(1, hasSession: false);
      await NotificationAuthTracker.observe(3);
      await NotificationAuthTracker.noteRequest(
        AuthRequestResult.parse({
          'granted': false,
          'before': 0,
          'after': 1,
          'errorDomain': 'NSCocoaErrorDomain',
          'errorCode': 4099,
          'active': true,
          'hasWindow': true,
        }, elapsedMs: 12),
        source: AuthRequestSource.setupPusher,
      );
      await Future<void>.delayed(Duration.zero);
      final tags = {
        ...await NotificationAuthTracker.reportTags(),
        ...ApnsPushService.notificationSettingsTags({'lockScreen': 1}),
      };
      final clean = Monitoring.sanitizePushReportTags(tags);
      expect(
        clean.keys.toSet(),
        tags.keys.toSet(),
        reason: 'тег вне словаря пропал бы молча',
      );
      for (final v in clean.values) {
        expect(v.length, lessThanOrEqualTo(32));
      }
      expect(clean['liza.lock_screen'], 'disabled');
      expect(clean['liza.auth_req_err'], 'NSCocoaErrorDomain:4099');
    },
  );

  // AC:RL-push-auth-request-telemetry/6
  group('requestPermission через канал', () {
    test('словарь натива → granted наружу, ответ в журнале', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'requestPermission') {
              return {'granted': true, 'before': 0, 'after': 2, 'active': true};
            }
            return null;
          });
      final ok = await ApnsPushService().requestPermission(
        source: AuthRequestSource.setupFirebase,
      );
      expect(ok, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final tags = await NotificationAuthTracker.reportTags();
      expect(tags['liza.auth_req'], 'authGranted');
      expect(tags['liza.auth_prompt'], 'authGranted');
    });

    test('старый натив (bool) по-прежнему работает', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _channel,
            (call) async => call.method == 'requestPermission' ? false : null,
          );
      expect(await ApnsPushService().requestPermission(), isFalse);
    });

    test('сбой натива не бросает и даёт false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            throw PlatformException(code: 'boom');
          });
      expect(await ApnsPushService().requestPermission(), isFalse);
      expect(await ApnsPushService().authorizationStatus(), isNull);
    });
  });

  // AC:RL-push-auth-request-telemetry/7
  test('счётчики push-report по исходам запроса и статусам', () {
    final now = DateTime.now();
    final j = PushJournal.forTest()
      ..record(
        PushStage.authRequest,
        reason: PushReason.authRefused,
        value: 0,
        now: now,
      )
      ..record(
        PushStage.authStatus,
        reason: PushReason.authDenied,
        value: -1,
        now: now,
      );
    final c = PushJournalStats.compute(
      j.entries,
      since: now.subtract(const Duration(days: 1)),
    );
    expect(c['auth_request.auth_refused'], 1);
    expect(c['auth_status.auth_denied'], 1);
    expect(jsonEncode(j.entries.first.toJson()).contains('"v":0'), isTrue);
  });

  // AC:RL-push-auth-request-telemetry/8
  test('оба нативных плагина отдают словарь ответа и экран блокировки', () {
    for (final path in [
      'macos/Runner/MacApnsPushPlugin.swift',
      'ios/Runner/ApnsPushPlugin.swift',
    ]) {
      final src = File(path).readAsStringSync();
      expect(
        src,
        contains('"before": before.authorizationStatus.rawValue'),
        reason: path,
      );
      expect(src, contains('out["errorDomain"] = ns.domain'), reason: path);
      expect(
        src,
        contains('"lockScreen": s.lockScreenSetting.rawValue'),
        reason: path,
      );
    }
  });

  // AC:RL-push-auth-request-telemetry/9
  test(
    'снимок вокруг запроса flutter_local_notifications закрыт гейтом isLocal',
    () {
      final src = File('lib/utils/background_push.dart').readAsStringSync();
      final probe = src.indexOf('final flnAuthProbe');
      final init = src.indexOf(
        'final flnGranted = await _flutterLocalNotificationsPlugin.initialize(',
      );
      expect(probe, greaterThan(0));
      expect(
        probe,
        lessThan(init),
        reason: '«до» читается строго раньше initialize',
      );
      expect(src.substring(probe, init), contains('!AppConfig.isLocal'));
      expect(src, contains('source: AuthRequestSource.fln'));
    },
  );
}
