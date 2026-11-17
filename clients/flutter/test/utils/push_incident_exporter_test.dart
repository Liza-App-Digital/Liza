// ignore_for_file: depend_on_referenced_packages
// ledger:RL-push-incident-export

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/push_incident_exporter.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/push_report_outbox.dart';

import 'push_report_test_support.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

Map<String, dynamic> _payload({
  List<Map<String, Object?>> accounts = const [],
}) => {
  'title': Monitoring.pushReportTitle('macos'),
  'tags': <String, String>{},
  'context': Monitoring.pushReportContext(
    counters: const {},
    journalTail: '',
    settings: const {},
    accounts: accounts,
    nativeJournal: const [],
    platform: 'macos',
  ),
};

List<Map<String, dynamic>> _dartRecords(Map state) => [
  for (final report in state['incidents'] as List)
    for (final line
        in (report['payload']['context']['journal'] as String).split('\n'))
      if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
];

PushIncidentRecord _record(int i, int time) => PushIncidentRecord({
  'id': '${'a' * 32}-$i',
  't': time,
  's': 'apns',
  'e128': PushJournal.hash128('\$e$i'),
  'kind': 'unknown',
}, native: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime.utc(2026, 11, 16);
  late Directory dir;
  late PathProviderPlatform oldPaths;
  late PushJournal journal;
  late MemoryPushReportStore store;
  late PushReportOutbox box;
  final exporters = <PushIncidentExporter>[];
  late bool online;
  late String answer;
  late List<Map<String, dynamic>> sent;

  setUp(() async {
    oldPaths = PathProviderPlatform.instance;
    dir = Directory.systemTemp.createTempSync('push_incident_');
    PathProviderPlatform.instance = _Paths(dir.path);
    journal = PushJournal.forTest();
    await journal.init();
    store = MemoryPushReportStore();
    online = false;
    answer = 'match';
    sent = [];
    box = PushReportOutbox(
      store: store,
      transport: () => CallbackPushReportTransport((report) {
        sent.add(report);
        return answer == 'match' ? report['event_id'] as String : answer;
      }),
    );
  });

  tearDown(() {
    for (final exporter in exporters) {
      exporter.dispose();
    }
    exporters.clear();
    journal.resetForTest();
    PathProviderPlatform.instance = oldPaths;
    dir.deleteSync(recursive: true);
  });

  PushIncidentExporter exporter({
    PushReportOutbox? outbox,
    Future<List<Map<String, Object>>> Function()? native,
    Map<String, dynamic> Function()? payload,
  }) {
    final result = PushIncidentExporter(
      journal: journal,
      outbox: outbox ?? box,
      payload: payload ?? _payload,
      readNative: native ?? () async => [],
      canSend: () => online,
      clock: () => t0,
      coalesce: const Duration(hours: 1),
    );
    exporters.add(result);
    return result;
  }

  // AC:RL-push-incident-export/1
  test(
    '8 событий закреплены до timer; fresh daily и 2100 других записей не теряют batch',
    () async {
      await box.enqueue(_payload(), t0);
      expect(await box.isDue(t0), isFalse);
      final ex = exporter()..start();
      await ex.replay();
      journal.configureObservedBuild('4242');
      for (var i = 0; i < 8; i++) {
        journal.record(
          i.isEven ? PushStage.local : PushStage.apns,
          eventId: '\$voice$i',
          accountName: 'private-account',
          now: t0,
          mediaKind: i.isEven ? PushMediaKind.voice : PushMediaKind.unknown,
        );
      }
      // Critical flush уже произошёл синхронно — ещё ни одного await.
      expect(
        File('${dir.path}/push_journal.jsonl').readAsLinesSync(),
        hasLength(8),
      );
      for (var i = 0; i < 2100; i++) {
        journal.record(PushStage.badge, value: i);
      }
      expect(
        journal.entries.any((e) => e.mediaKind == PushMediaKind.voice),
        isFalse,
      );
      await ex.flush();
      final state = await box.inspect();
      expect(state['reports'], hasLength(1));
      expect(state['incidents'], hasLength(1));
      final records = _dartRecords(state);
      expect(records, hasLength(8));
      expect(records.every((r) => r['observed_build'] == '4242'), isTrue);
      expect(records.every((r) => r['process_role'] == 'dart'), isTrue);
      expect(records.map((r) => r['id']).toSet(), hasLength(8));
      expect(jsonEncode(state), isNot(contains('private-account')));
      expect(sent, isEmpty);
      final captured = (state['incidents'] as List).single;
      expect(captured['payload']['context']['report_kind'], 'incident');
    },
  );

  // AC:RL-push-incident-export/2
  test(
    'clearing/count-only не триггерят; late stage после ACK новый immutable batch',
    () async {
      final ex = exporter()..start();
      await ex.replay();
      journal.record(
        PushStage.apns,
        eventId: r'$clearing',
        reason: PushReason.clearing,
        now: t0,
      );
      journal.record(PushStage.apns, now: t0);
      journal.record(
        PushStage.local,
        eventId: r'$text',
        mediaKind: PushMediaKind.other,
        now: t0,
      );
      await ex.flush();
      expect((await box.inspect())['incidents'], isEmpty);
      journal.record(
        PushStage.apns,
        eventId: r'$tracked',
        accountName: 'account',
        now: t0,
      );
      online = true;
      await ex.flush();
      expect(sent, hasLength(1));
      final original = jsonEncode(sent.single);
      expect((await box.inspect())['incidents'], isEmpty);
      journal.record(
        PushStage.retract,
        eventId: r'$tracked',
        accountName: 'account',
        value: 15,
        now: t0,
      );
      await ex.flush();
      expect(sent, hasLength(2));
      expect(sent.last['event_id'], isNot(sent.first['event_id']));
      expect(jsonEncode(sent.first), original);
      final late = sent.last['payload']['context']['journal'] as String;
      expect(jsonDecode(late)['s'], 'retract');
      await ex.replay();
      expect(sent, hasLength(2), reason: 'seen переживает ACK');
    },
  );

  // AC:RL-push-incident-export/3
  test(
    'store failure не ставит seen; restart, wrong ACK и later stage сохраняются',
    () async {
      final ex = exporter()..start();
      await ex.replay();
      store.failWrite = true;
      journal.record(
        PushStage.apns,
        eventId: r'$retry',
        accountName: 'a',
        now: t0,
      );
      await ex.flush();
      expect((await box.inspect())['seen'], isEmpty);
      expect((await box.inspect())['incidents'], isEmpty);
      store.failWrite = false;
      await ex.flush();
      ex.dispose();
      final queued = (await box.inspect())['incidents'];
      journal.resetForTest();
      await journal.init();
      final resumedBox = PushReportOutbox(
        store: store,
        transport: () => CallbackPushReportTransport((r) => 'wrong'),
      );
      final resumed = exporter(outbox: resumedBox)..start();
      await resumed.replay();
      expect((await resumedBox.inspect())['incidents'], queued);
      online = true;
      await resumed.flush();
      expect((await resumedBox.inspect())['incidents'], hasLength(1));
      journal.record(
        PushStage.retract,
        eventId: r'$retry',
        accountName: 'a',
        now: t0,
      );
      online = false;
      await resumed.flush();
      expect((await resumedBox.inspect())['incidents'], hasLength(2));
      expect(_dartRecords(await resumedBox.inspect()).map((r) => r['s']), [
        'apns',
        'retract',
      ]);
    },
  );

  // AC:RL-push-incident-export/4
  test(
    'record во время network drain закрепляется и уходит следующим batch',
    () async {
      final blocked = Completer<String?>();
      final entered = Completer<void>();
      String? id;
      var calls = 0;
      final blockingBox = PushReportOutbox(
        store: store,
        transport: () => CallbackPushReportTransport((r) {
          calls++;
          if (calls == 1) {
            id = r['event_id'] as String;
            entered.complete();
            return blocked.future;
          }
          return r['event_id'] as String;
        }),
      );
      final ex = exporter(outbox: blockingBox)..start();
      await ex.replay();
      online = true;
      journal.record(PushStage.apns, eventId: r'$one', now: t0);
      final flight = ex.flush();
      await entered.future;
      journal.record(PushStage.apns, eventId: r'$two', now: t0);
      for (var i = 0; i < 2100; i++) {
        journal.record(PushStage.badge);
      }
      blocked.complete(id);
      await flight;
      await ex.flush();
      expect(calls, 2);
      expect((await blockingBox.inspect())['incidents'], isEmpty);
    },
  );

  // AC:RL-push-incident-export/5
  test(
    'v2 с 7 daily мигрирует без потери; две lane count/bytes и TTL ограничены',
    () async {
      for (var i = 0; i < 7; i++) {
        final value = _payload();
        value['context']['journal'] = 'я' * 15000;
        await box.enqueue(value, t0.add(Duration(minutes: i)), manual: true);
      }
      final old = await box.inspect();
      final originalDaily = jsonEncode(old['reports']);
      final legacy = {
        for (final key in [
          'installation_id',
          'reports',
          'evicted',
          'expired',
          'corrupt',
          'oversized',
          'last_manual',
        ])
          key: old[key],
        'version': 2,
      };
      store.value = jsonEncode(legacy);
      final migrated = PushReportOutbox(
        store: store,
        transport: () => CallbackPushReportTransport((_) => null),
      );
      expect(jsonEncode((await migrated.inspect())['reports']), originalDaily);
      for (var i = 0; i < 9; i++) {
        final value = _payload();
        value['context']['padding'] = 'я' * 20000;
        await migrated.enqueueIncident(value, [
          _record(i, t0.millisecondsSinceEpoch + i),
        ], t0);
      }
      var state = await migrated.inspect();
      expect(jsonEncode(state['reports']), originalDaily);
      expect((state['incidents'] as List).length, lessThanOrEqualTo(7));
      expect(state['incident_evicted'], greaterThan(0));
      for (final lane in ['reports', 'incidents']) {
        expect(
          utf8.encode(jsonEncode(state[lane])).length,
          lessThanOrEqualTo(256 * 1024),
        );
      }
      expect(utf8.encode(store.value!).length, lessThanOrEqualTo(576 * 1024));
      final oversized = _payload();
      oversized['context']['padding'] = 'x' * 256 * 1024;
      final beforeSeen = state['seen'];
      expect(
        await migrated.enqueueIncident(oversized, [
          _record(999, t0.millisecondsSinceEpoch),
        ], t0),
        isEmpty,
      );
      state = await migrated.inspect();
      expect(state['incident_oversized'], 1);
      expect(state['seen'], beforeSeen);
      await migrated.drain(
        t0.add(const Duration(days: 8)),
        canSend: () => false,
      );
      state = await migrated.inspect();
      expect(state['reports'], isEmpty);
      expect(state['incidents'], isEmpty);
      expect(state['expired'], 7);
      expect(state['incident_expired'], greaterThan(0));
    },
  );

  // AC:RL-push-incident-export/6
  test(
    'seen только included; >512 одно-временных records и historical late native не режутся',
    () async {
      final all = List.generate(
        600,
        (i) => _record(i, t0.millisecondsSinceEpoch),
      );
      final remaining = {for (final r in all) r.key: r};
      final capturedIds = <String>{};
      while (remaining.isNotEmpty) {
        final handled = await box.enqueueIncident(
          _payload(),
          remaining.values.toList(),
          t0,
        );
        expect(handled, isNotEmpty);
        final reports = (await box.inspect())['incidents'] as List;
        final recordLines =
            (reports.last['payload']['context']['journal'] as String).split(
              '\n',
            );
        capturedIds.addAll(
          recordLines.map((l) => jsonDecode(l)['id'] as String),
        );
        for (final key in handled) {
          remaining.remove(key);
        }
      }
      expect(capturedIds, hasLength(600));
      final before = (await box.inspect())['incidents'] as List;
      expect(await box.enqueueIncident(_payload(), all, t0), hasLength(600));
      expect((await box.inspect())['incidents'], before);
      final historical = PushIncidentRecord({
        'id': '00000000-0000-4000-8000-000000000000',
        't': t0.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        's': 'deliveredObserved',
        'event_hash': PushJournal.hash128(r'$old'),
      }, native: true);
      expect(await box.enqueueIncident(_payload(), [historical], t0), {
        historical.key,
      });
      final latest = ((await box.inspect())['incidents'] as List).last;
      expect(latest['payload']['context']['native_journal'], hasLength(1));
    },
  );

  // AC:RL-push-incident-export/7
  test(
    'startup full replay и native failure независимы, captured accounts не меняются после logout',
    () async {
      for (var i = 0; i < 200; i++) {
        journal.record(PushStage.apns, eventId: '\$initial$i', now: t0);
      }
      final accounts = <Map<String, Object?>>[
        {
          'user_id': '@one:example.org',
          'account_hash128': PushJournal.hash128('one'),
        },
      ];
      final ex = exporter(
        native: () async => throw StateError('native unavailable'),
        payload: () => _payload(accounts: accounts),
      );
      final replay = ex.replay(); // закрепляет все 200 записей до await
      accounts.clear();
      await replay;
      final state = await box.inspect();
      expect(_dartRecords(state), hasLength(200), reason: 'не 24KB tail');
      final contexts = (state['incidents'] as List).map(
        (r) => r['payload']['context'],
      );
      expect(contexts.every((c) => (c['accounts'] as List).isNotEmpty), isTrue);
      expect(
        contexts.first['incident_export']['source_errors_since_start'],
        greaterThan(0),
      );
    },
  );

  // AC:RL-push-incident-export/8
  test(
    'shared immutable payload учитывается в buffer budget и counters показывают bound',
    () async {
      final accounts = List.generate(
        16,
        (i) => <String, Object?>{
          'user_id': '@$i:${'a' * 1500}',
          'account_hash128': PushJournal.hash128('$i'),
        },
      );
      final ex = exporter(payload: () => _payload(accounts: accounts))..start();
      await ex.replay();
      for (var i = 0; i < 180; i++) {
        journal.record(PushStage.apns, eventId: '\$buffer$i', now: t0);
      }
      await ex.flush();
      final state = await box.inspect();
      final reports = state['incidents'] as List;
      expect(reports, isNotEmpty);
      final coverage = reports.first['payload']['context']['incident_export'];
      expect(
        coverage['buffer_bytes'],
        lessThanOrEqualTo(PushIncidentExporter.maxBufferBytes),
      );
      expect(coverage['buffer_evictions_since_start'], 0);
      expect(coverage['tracked_evictions_since_start'], greaterThan(0));
      expect(
        utf8.encode(store.value!).length,
        lessThanOrEqualTo(PushReportOutbox.maxBytes),
      );
    },
  );

  // AC:RL-push-incident-export/10
  test(
    'incident переносит native cumulative loss/read status и async crash gap',
    () async {
      final ex = PushIncidentExporter(
        journal: journal,
        outbox: box,
        payload: _payload,
        clock: () => t0,
        canSend: () => false,
        nativeStatus: () => 'partial',
        readNative: () async => [
          {
            'id': 'native-diagnostic-loss',
            't': t0.millisecondsSinceEpoch,
            's': 'diagnosticLoss',
            'value': 9,
          },
        ],
      );
      exporters.add(ex);
      journal.record(PushStage.apns, eventId: r'$with-native-gap', now: t0);
      await ex.replay();
      final context = ((await box.inspect())['incidents'] as List)
          .single['payload']['context'];
      expect(context['native_loss'], 9);
      expect(context['coverage']['native_journal'], 'partial');
      expect(context['coverage']['native_read_status'], 'partial');
      expect(
        context['coverage']['native_read_observed_at'],
        t0.toIso8601String(),
      );
      expect(
        context['coverage']['native_loss_semantics'],
        'cumulative_unknown_window',
      );
      expect(context['coverage']['native_persistence'], 'best_effort');
      expect(
        context['coverage']['native_crash_tail'],
        'async_pending_unknown_after_process_exit',
      );
      expect(context['coverage']['native_window'], 'unknown');
      expect(context['coverage']['os_display'], 'unknown');
    },
  );

  // AC:RL-push-incident-export/11
  test(
    'packed LRU удерживает retained union; byte budget включает metadata',
    () async {
      for (var i = 0; i < 7; i++) {
        final p = _payload();
        p['context']['journal'] = 'я' * 15000;
        await box.enqueue(p, t0.add(Duration(minutes: i)), manual: true);
      }
      final all = List.generate(
        2400,
        (i) => _record(i, t0.millisecondsSinceEpoch),
      );
      final pending = {for (final r in all) r.key: r};
      while (pending.isNotEmpty) {
        final handled = await box.enqueueIncident(
          _payload(),
          pending.values.toList(),
          t0,
        );
        expect(handled, isNotEmpty);
        for (final key in handled) {
          pending.remove(key);
        }
      }
      final state = await box.inspect();
      expect((state['seen'] as String).length, PushReportOutbox.seenLimit * 22);
      expect(state['seen_evicted'], 2400 - PushReportOutbox.seenLimit);
      expect(state['reports'], hasLength(7));
      expect(
        utf8.encode(store.value!).length,
        lessThanOrEqualTo(PushReportOutbox.maxBytes),
      );
      final retained = all.sublist(all.length - 2256);
      expect(
        await box.enqueueIncident(_payload(), retained, t0),
        hasLength(2256),
      );
      expect((await box.inspect())['incidents'], state['incidents']);
    },
  );

  // AC:RL-push-incident-export/12
  test(
    'build не подставляется задним числом; malformed provenance не экспортируется',
    () {
      journal.record(PushStage.apns, eventId: r'$before', now: t0);
      journal.configureObservedBuild('4242');
      journal.record(PushStage.apns, eventId: r'$after', now: t0);
      expect(
        journal.entries.first.toJson().containsKey('observed_build'),
        isFalse,
      );
      expect(journal.entries.last.toJson()['observed_build'], '4242');
      expect(journal.entries.first.runId, journal.entries.last.runId);
      const unsafe = PushJournalEntry(
        timeMs: 1,
        stage: PushStage.apns,
        runId: 'private-session',
        observedBuild: 'private-filename',
      );
      expect(unsafe.toJson(), {'t': 1, 's': 'apns'});
    },
  );

  // AC:RL-push-incident-export/14
  test('non-mac noEvent с event ID экспортирует voice/audio/unknown', () async {
    final ex = exporter()..start();
    await ex.replay();
    // handleApnsMessage вне macOS записывает noEvent перед deliver даже
    // при наличии event_id. Это отсутствие macOS-вердикта, а не события.
    for (final kind in [
      PushMediaKind.voice,
      PushMediaKind.audio,
      PushMediaKind.unknown,
    ]) {
      journal.record(
        PushStage.apns,
        reason: PushReason.noEvent,
        eventId: '\$non-mac-${kind.name}',
        mediaKind: kind,
        source: PushObservationSource.apnsPreview,
        now: t0,
      );
    }
    journal.record(PushStage.apns, reason: PushReason.noEvent, now: t0);
    journal.record(
      PushStage.apns,
      reason: PushReason.noEvent,
      eventId: '',
      mediaKind: PushMediaKind.voice,
      now: t0,
    );
    journal.record(
      PushStage.apns,
      reason: PushReason.clearing,
      eventId: r'$untracked-clearing',
      mediaKind: PushMediaKind.audio,
      now: t0,
    );
    // Clearing не становится стадией инцидента даже для уже tracked event.
    journal.record(
      PushStage.apns,
      reason: PushReason.clearing,
      eventId: r'$non-mac-voice',
      mediaKind: PushMediaKind.voice,
      now: t0,
    );
    await ex.flush();
    final records = _dartRecords(await box.inspect());
    expect(records, hasLength(3));
    expect(records.map((r) => r['kind']).toSet(), {
      'voice',
      'audio',
      'unknown',
    });
    expect(records.every((r) => r['r'] == 'noEvent'), isTrue);
    expect(records.map((r) => r['e128']).toSet(), {
      for (final kind in ['voice', 'audio', 'unknown'])
        PushJournal.hash128('\$non-mac-$kind'),
    });
  });
}
