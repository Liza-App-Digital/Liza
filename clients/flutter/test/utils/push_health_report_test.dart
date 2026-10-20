// ignore_for_file: depend_on_referenced_packages

// Страж телеметрии пушей (спека 2026-10-16-push-telemetry-cohorts-design.md):
// суточный `[health] push-report` + журнал пути уведомлений на устройстве.
//
// Инварианты: title тихий и не маскирует heartbeat (без `env=`); в отчёт
// структурно не попадает текст/mxid/сырые id; журнал ограничен и терпим к
// битым строкам; запись журнала — наблюдатель (не меняет решение баннера);
// атрибуция ставится восстановленным сессиям; хеш совпадает с серверным.
//
// ledger:RL-push-health-report

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/apns_push_service.dart';
import 'package:liza/utils/background_push.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/push_journal.dart';

import 'per_user_fake_api.dart';
import 'test_client.dart';

const _platforms = ['macos', 'ios', 'android', 'windows', 'linux', 'web'];

/// Значения, которых НИ ПРИ КАКИХ стадиях не должно быть в отчёте.
const _secretEvent = r'$SecretEvt42:synapse.liza.laba.prodamus.tech';
const _secretRoom = '!SecretRoom42:synapse.liza.laba.prodamus.tech';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.supportPath);
  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

class _ThrowingJournal extends PushJournal {
  _ThrowingJournal() : super.forTest();

  @override
  void record(
    PushStage stage, {
    PushReason? reason,
    AppLifecycleState? state,
    String? eventId,
    String? roomId,
    int? value,
    DateTime? now,
  }) => throw StateError('журнал сломан');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AC:RL-push-health-report/1
  test('title отчёта: ∀ платформа — маркер [health], без env=, ≤100', () {
    for (final p in _platforms) {
      final t = Monitoring.pushReportTitle(p);
      expect(t, matches(RegExp(r'^\[health\] push-report platform=[a-z]+$')));
      expect(
        t.contains('env='),
        isFalse,
        reason: 'env= в title маскирует heartbeat',
      );
      expect(t.length, lessThanOrEqualTo(100));
    }
  });

  // AC:RL-push-health-report/4
  test('отчёт ∀ стадия журнала не несёт сырых id, mxid и текста', () async {
    SharedPreferences.setMockInitialValues({});
    final j = PushJournal.forTest();
    final now = DateTime(2026, 10, 16, 12);
    for (final stage in PushStage.values) {
      j.record(
        stage,
        reason: PushReason.show,
        eventId: _secretEvent,
        roomId: _secretRoom,
        value: 7,
        state: AppLifecycleState.hidden,
        now: now,
      );
    }
    String? title;
    Map<String, String>? tags;
    Map<String, Object>? extra;
    await Monitoring.reportPushHealth(
      platform: 'macos',
      tags: {
        'liza.os_version': '13.7',
        'liza.user': '@aleksandr.novokshonov:synapse.liza.laba.prodamus.tech',
      },
      counters: PushJournalStats.compute(
        j.entries,
        since: now.subtract(const Duration(days: 1)),
      ),
      journalTail: PushJournal.tail(j.entries, Monitoring.pushReportTailBytes),
      now: now,
      send: (t, tg, ex) {
        title = t;
        tags = tg;
        extra = ex;
      },
    );
    final blob = jsonEncode({'title': title, 'tags': tags, 'extra': extra});
    for (final forbidden in [
      '@',
      '!',
      r'$',
      'mxc://',
      'SecretEvt42',
      'SecretRoom42',
      'pushkey',
    ]) {
      expect(
        blob.contains(forbidden),
        isFalse,
        reason: 'в отчёте «$forbidden»',
      );
    }
    expect(
      (extra!['journal'] as String).split('\n').length,
      PushStage.values.length,
    );
  });

  // AC:RL-push-health-report/5
  test('нативная запись: чужая стадия/причина/поля отбрасываются', () {
    final j = PushJournal.forTest();
    j.recordNative({'stage': 'evil', 'reason': 'show'});
    j.recordNative({
      'stage': 'native',
      'reason': 'текст сообщения',
      'body': 'привет',
      'eventId': _secretEvent,
    });
    j.recordNative('not a map');
    expect(j.entries.length, 1);
    final json = j.entries.single.toJson();
    expect(
      json.keys.toSet().difference({'t', 's', 'r', 'st', 'e', 'rm', 'v'}),
      isEmpty,
    );
    expect(json['r'], isNull, reason: 'причина не из перечня — не пишется');
    expect(json['e'], PushJournal.hash8(_secretEvent));
  });

  test(
    'нативная запись берёт время натива (сон фиксируется до заморозки Dart)',
    () {
      final j = PushJournal.forTest();
      final sleptAt = DateTime(2026, 10, 15, 21, 44).millisecondsSinceEpoch;
      j.recordNative({'stage': 'sleep', 'reason': 'system', 'timeMs': sleptAt});
      expect(j.entries.single.timeMs, sleptAt);
    },
  );

  // AC:RL-push-health-report/6
  test(
    'журнал ограничен: 3000 записей → ≤2000; хвост ≤24 КБ и из новейших',
    () {
      final j = PushJournal.forTest();
      final base = DateTime(2026, 10, 16);
      for (var i = 0; i < 3000; i++) {
        j.record(
          PushStage.apns,
          reason: PushReason.show,
          eventId: '\$e$i',
          roomId: '!r$i',
          value: i,
          now: base.add(Duration(seconds: i)),
        );
      }
      expect(j.entries.length, PushJournal.maxEntries);
      final tail = PushJournal.tail(j.entries, Monitoring.pushReportTailBytes);
      expect(
        utf8.encode(tail).length,
        lessThanOrEqualTo(Monitoring.pushReportTailBytes),
      );
      final last = PushJournalEntry.tryParse(tail.split('\n').last)!;
      expect(last.value, 2999, reason: 'хвост — новейшие записи');
    },
  );

  test('битые строки журнала не роняют разбор', () {
    expect(PushJournalEntry.tryParse('{"t":1,"s":"apns"'), isNull);
    expect(PushJournalEntry.tryParse('{"t":"x","s":"apns"}'), isNull);
    expect(
      PushJournalEntry.tryParse(
        '{"t":1,"s":"apns","e":"not-a-hash"}',
      )!.eventHash,
      isNull,
    );
    expect(
      PushJournalEntry.tryParse('{"t":1,"s":"wake","r":"system"}')!.stage,
      PushStage.wake,
    );
  });

  // AC:RL-push-health-report/13
  test(
    'hash8 совпадает с серверным push_fleet_report.hash8 (общий вектор)',
    () {
      expect(PushJournal.hash8(r'$qbjlZmg14Tcfdz3P6kXuPC8:vector'), 'a7efac91');
    },
  );

  test('счётчики: латентность, сон системы/дисплея, пропасти sync', () {
    final j = PushJournal.forTest();
    final t0 = DateTime(2026, 10, 15, 21);
    for (final (min, lat) in [(0, 1), (1, 2), (2, 2655), (3, 731)]) {
      j.record(
        PushStage.apns,
        reason: PushReason.show,
        eventId: '\$e$min',
        value: lat,
        now: t0.add(Duration(minutes: min)),
      );
    }
    // Не alert-пуши: в «получено» (сверка с отправками Sygnal) не входят.
    j.record(PushStage.apns, reason: PushReason.clearing, now: t0);
    j.record(
      PushStage.apns,
      reason: PushReason.duplicate,
      eventId: r'$e0',
      now: t0,
    );
    j.recordNative({
      'stage': 'sleep',
      'reason': 'system',
      'timeMs': t0.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    });
    j.recordNative({
      'stage': 'wake',
      'reason': 'system',
      'timeMs': t0.add(const Duration(minutes: 25)).millisecondsSinceEpoch,
    });
    j.recordNative({
      'stage': 'sleep',
      'reason': 'screens',
      'timeMs': t0.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
    });
    j.noteSync(now: t0.add(const Duration(minutes: 40)));
    j.noteSync(now: t0.add(const Duration(minutes: 40, seconds: 30)));
    j.noteSync(now: t0.add(const Duration(minutes: 56)));
    final s = PushJournalStats.compute(j.entries, since: t0);
    expect(s['apns_received'], 4);
    expect(s['apns_latency_max_s'], 2655);
    expect(s['apns_late_2m'], 2);
    expect(s['apns.show'], 4);
    expect(s['apns.clearing'], 1);
    expect(s['sleep_count'], 1);
    expect(s['sleep_minutes'], 15);
    expect(s['screen_sleep_count'], 1);
    expect(
      s['sync_gap_count'],
      1,
      reason: '30 с — норма long-poll, 15 мин — пропасть',
    );
    expect(s['sync_gap_max_s'], 930);
  });

  // AC:RL-push-health-report/9
  test(
    'атрибуция: основной аккаунт → user, остальные — тегом; пусто → снять',
    () {
      final none = Monitoring.identityFor(const []);
      expect(none.user, isNull);
      final two = Monitoring.identityFor(const [
        (
          userId: '@aleksandr.novokshonov:synapse.liza.laba.prodamus.tech',
          deviceId: 'NGHQXOHAXH',
        ),
        (userId: '@second:liza.cyber-agro.ru', deviceId: 'OTHER'),
      ]);
      expect(
        two.user!.id,
        '@aleksandr.novokshonov:synapse.liza.laba.prodamus.tech',
      );
      expect(two.user!.username, 'aleksandr.novokshonov');
      expect(two.tags, {'liza.accounts': '2', 'liza.device_id': 'NGHQXOHAXH'});
    },
  );

  // AC:RL-push-health-report/9b — корень дефекта был в точке вызова: восстановленные
  // сессии `loggedIn` не получают, значит атрибуция обязана стоять в initMatrix.
  test('initMatrix ставит атрибуцию сам, не полагаясь на loggedIn', () {
    final src = File('lib/widgets/matrix.dart').readAsStringSync();
    final init = src.substring(src.indexOf('void initMatrix() {'));
    final body = init.substring(0, init.indexOf('\n  }\n'));
    expect(body.contains('_syncMonitoringIdentity();'), isTrue);
    expect(
      src.contains('Monitoring.setUserIdentity('),
      isFalse,
      reason: 'единая точка — syncIdentity',
    );
  });

  // AC:RL-push-health-report/10
  test(
    'троттл 24 ч; отметка пишется ДО отправки (сбой не даёт повтор)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final t0 = DateTime(2026, 10, 16, 9);
      var sent = 0;
      Future<bool> run(DateTime at, {bool fail = false}) =>
          Monitoring.reportPushHealth(
            platform: 'macos',
            tags: const {},
            counters: const {},
            journalTail: '',
            now: at,
            send: (_, _, _) {
              if (fail) throw StateError('сеть');
              sent++;
            },
          );
      expect(await run(t0), isTrue);
      expect(await run(t0.add(const Duration(hours: 3))), isFalse);
      expect(await run(t0.add(const Duration(hours: 25)), fail: true), isFalse);
      expect(
        await run(t0.add(const Duration(hours: 26))),
        isFalse,
        reason: 'сбой отправки не открывает окно заново',
      );
      expect(await run(t0.add(const Duration(hours: 50))), isTrue);
      expect(sent, 2);
    },
  );

  // AC:RL-push-health-report/11
  test('теги: только словарь когорты, значения ≤32', () {
    final out = Monitoring.sanitizePushReportTags({
      'liza.os_version': '13.7',
      'liza.install_location': 'x' * 80,
      'liza.user': '@a:b',
      'random': 'v',
      'liza.app_copies': '',
    });
    expect(out.keys.toSet(), {'liza.os_version', 'liza.install_location'});
    expect(out['liza.install_location']!.length, 32);
  });

  test(
    'нативные пробы → стабильные теги (alertStyle — главный подозреваемый)',
    () {
      expect(
        ApnsPushService.notificationSettingsTags({
          'authorization': 2,
          'alert': 2,
          'alertStyle': 0,
          'badge': 1,
          'sound': 2,
          'notificationCenter': 2,
        }),
        {
          'liza.auth': 'authorized',
          'liza.alert': 'enabled',
          'liza.alert_style': 'none',
          'liza.badge_setting': 'disabled',
          'liza.sound_setting': 'enabled',
          'liza.nc_setting': 'enabled',
        },
      );
      expect(
        ApnsPushService.appCopiesTags({
          'copies': 2,
          'legacyCopies': 1,
          'running': 1,
          'location': 'applications',
        }),
        {
          'liza.app_copies': '2',
          'liza.legacy_copies': '1',
          'liza.running_copies': '1',
          'liza.install_location': 'applications',
        },
      );
    },
  );

  test('osMajorMinor: строки ОС разных платформ', () {
    expect(osMajorMinor('Version 13.7.8 (Build 22H730)'), '13.7');
    expect(osMajorMinor('Version 26.6 (Build 25G241)'), '26.6');
    expect(osMajorMinor('"Windows 11 Pro" 10.0 (Build 26100)'), '10.0');
    expect(osMajorMinor('Android 14'), '14');
  });

  // AC:RL-push-health-report/12
  test(
    'showLocalNotification: каждый ранний выход оставляет запись с причиной',
    () {
      final src = File(
        'lib/widgets/local_notifications_extension.dart',
      ).readAsStringSync();
      final start = src.indexOf(
        'void showLocalNotification(Event event) async {',
      );
      final gates = src.substring(
        start,
        src.indexOf('markLocallyShown(event.eventId)', start),
      );
      expect(
        RegExp(r'return;').hasMatch(gates),
        isFalse,
        reason: 'молчаливый выход',
      );
      for (final r in [
        'newsAudience',
        'activeRoom',
        'hiddenRoom',
        'tooOld',
        'apnsHandled',
      ]) {
        expect(gates.contains('return skip(PushReason.$r)'), isTrue, reason: r);
      }
    },
  );

  // AC:RL-push-health-report/8
  test(
    'натив пишет в журнал только ПОСЛЕ ответа системе (completionHandler)',
    () {
      final lines = File('macos/Runner/AppDelegate.swift').readAsLinesSync();
      final calls = [
        for (var i = 0; i < lines.length; i++)
          if (lines[i].contains('MacApnsPushPlugin.journal(')) i,
      ];
      expect(calls.length, greaterThanOrEqualTo(5));
      for (final i in calls) {
        final window = lines.sublist(i - 6 < 0 ? 0 : i - 6, i).join('\n');
        expect(
          window.contains('completionHandler('),
          isTrue,
          reason: 'строка ${i + 1}',
        );
      }
    },
  );

  // AC:RL-push-health-report/17
  test(
    'журнал: записи до init попадают в файл и на первом старте (файла нет)',
    () async {
      final dir = Directory.systemTemp.createTempSync('push_journal_');
      addTearDown(() => dir.deleteSync(recursive: true));
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final j = PushJournal.forTest();
      final t0 = DateTime(2026, 10, 16, 9);
      j.record(
        PushStage.apns,
        reason: PushReason.show,
        eventId: r'$cold',
        now: t0,
      );
      await j.init();
      j.record(PushStage.local, reason: PushReason.shown, now: t0);
      j.flush();
      final lines = File('${dir.path}/push_journal.jsonl').readAsLinesSync();
      expect(lines, hasLength(2));
      expect(lines.map(PushJournalEntry.tryParse).map((e) => e!.stage), [
        PushStage.apns,
        PushStage.local,
      ]);
    },
  );

  group('handleApnsMessage', () {
    late Client a;
    late BackgroundPush push;
    const room = '!room:nadezhda.liza.ru';

    setUp(() async {
      a = await prepareTestClient(
        loggedIn: true,
        clientName: 'Liza-journal',
        userId: '@nadezhda.rozental:nadezhda.liza.ru',
        homeserver: Uri.parse('https://nadezhda.liza.ru'),
        httpClient: PerUserFakeMatrixApi(
          userId: '@nadezhda.rozental:nadezhda.liza.ru',
          homeserverHost: 'nadezhda.liza.ru',
        ),
      );
      push = BackgroundPush.forTest([a]);
    });

    tearDown(() async => a.dispose());

    // AC:RL-push-health-report/7
    test('∀ decision: сломанный журнал не меняет outcome', () async {
      Future<(ApnsBannerDecision, String?)> run(
        String id,
        PushJournal journal,
      ) async {
        final out = await push.handleApnsMessage(
          {'room_id': room, 'event_id': id},
          retract: (_) async => 100,
          deliver: (_) async {},
          report: (_, _) {},
          journal: journal,
        );
        return (out.decision, out.retract);
      }

      final cases = <String, void Function(String)>{
        'suppressLocal': push.markLocallyShown,
        'unknownEvent': (_) {},
      };
      for (final entry in cases.entries) {
        entry.value('\$ok-${entry.key}');
        entry.value('\$bad-${entry.key}');
        final ok = await run('\$ok-${entry.key}', PushJournal.forTest());
        final bad = await run('\$bad-${entry.key}', _ThrowingJournal());
        expect(bad, ok, reason: entry.key);
      }
      final noEvent = await push.handleApnsMessage(
        {'room_id': room},
        deliver: (_) async {},
        journal: _ThrowingJournal(),
      );
      expect(noEvent.decision, ApnsBannerDecision.noEvent);
    }, skip: !Platform.isMacOS);

    test(
      'пришедший APNs пишется в журнал с hash8 и латентностью',
      () async {
        final j = PushJournal.forTest();
        await push.handleApnsMessage(
          {'room_id': room, 'event_id': r'$journaled'},
          retract: (_) async => null,
          deliver: (_) async {},
          report: (_, _) {},
          journal: j,
        );
        final e = j.entries.singleWhere((e) => e.stage == PushStage.apns);
        expect(e.eventHash, PushJournal.hash8(r'$journaled'));
        expect(e.roomHash, PushJournal.hash8(room));
      },
      skip: !Platform.isMacOS,
    );
  });
}
