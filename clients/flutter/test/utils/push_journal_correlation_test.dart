// ignore_for_file: depend_on_referenced_packages

// ledger:RL-macos-push-collision-observability

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:liza/utils/push_acks.dart';
import 'package:liza/utils/push_journal.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

/// Задерживает реальное чтение, чтобы record попал между await внутри init.
class _DelayedReadFile implements File {
  _DelayedReadFile(this.delegate);
  final File delegate;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> exists() => delegate.exists();

  @override
  bool existsSync() => delegate.existsSync();

  @override
  int lengthSync() => delegate.lengthSync();

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) async {
    started.complete();
    await release.future;
    return delegate.readAsLines(encoding: encoding);
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => delegate.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late PathProviderPlatform originalPaths;
  late PushJournal journal;

  setUp(() {
    originalPaths = PathProviderPlatform.instance;
    dir = Directory.systemTemp.createTempSync('push_correlation_');
    PathProviderPlatform.instance = _Paths(dir.path);
    journal = PushJournal.forTest();
  });

  tearDown(() {
    journal.resetForTest();
    PathProviderPlatform.instance = originalPaths;
    dir.deleteSync(recursive: true);
  });

  // AC:RL-macos-push-collision-observability/9
  test('корреляция сохраняется record → flush → reload → JSONL', () async {
    const event = r'$личное-событие:сервер';
    const account = 'Личный аккаунт';
    const target = r'$секретная-цель';
    final now = DateTime.utc(2026, 11, 16);
    journal.record(
      PushStage.collision,
      reason: PushReason.suppressLocal,
      eventId: event,
      accountName: account,
      relationTargetId: target,
      mediaKind: PushMediaKind.voice,
      relationKind: PushRelationKind.reply,
      source: PushObservationSource.localEvent,
      value: 1400,
      now: now,
    );
    final before = journal.entries.single.toJson();
    await journal.init();
    journal.flush();
    journal.resetForTest();
    await journal.init();
    final entry = journal.entries.single;
    expect(entry.toJson(), before);
    expect(entry.eventHash128, pushAckHash(event));
    expect(entry.accountHash128, pushAckHash(account));
    expect(entry.relationTargetHash128, pushAckHash(target));
    expect(entry.recordId, matches(r'^[0-9a-f]{32}-[0-9]+$'));
    expect(entry.value, 1400);
    expect(entry.timeMs, now.millisecondsSinceEpoch);
    final exported = PushJournal.tail(journal.entries, 24 * 1024);
    expect(PushJournalEntry.tryParse(exported)!.toJson(), before);
    for (final secret in [event, account, target]) {
      expect(exported, isNot(contains(secret)));
      expect(
        File('${dir.path}/push_journal.jsonl').readAsStringSync(),
        isNot(contains(secret)),
      );
    }
    final stats = PushJournalStats.compute(journal.entries, since: now);
    expect(stats['collision_risk'], 1);
    expect(stats['apns_received'], 0);
    expect(stats['local_shown'], 0);
  });

  // AC:RL-macos-push-collision-observability/9
  test('одинаковая миллисекунда не объединяет разные наблюдения', () {
    final now = DateTime.utc(2026, 11, 16);
    for (var i = 0; i < 200; i++) {
      journal.record(PushStage.apns, eventId: r'$same', now: now);
    }
    final snapshot = journal.entries;
    expect(snapshot.map((e) => e.recordId).toSet(), hasLength(200));
    expect(
      PushJournal.tail(snapshot, 100000),
      PushJournal.tail(journal.entries, 100000),
    );
    for (final entry in snapshot) {
      expect(
        PushJournalEntry.tryParse(jsonEncode(entry.toJson()))!.recordId,
        entry.recordId,
      );
    }
    final other = PushJournal.forTest();
    addTearDown(other.resetForTest);
    other.record(PushStage.apns, eventId: r'$same', now: now);
    expect(
      snapshot.map((e) => e.recordId),
      isNot(contains(other.entries.single.recordId)),
    );
  });

  // AC:RL-macos-push-collision-observability/9
  test('legacy и испорченные optional поля не выдают ложную корреляцию', () {
    final legacy = PushJournalEntry.tryParse(
      '{"t":1,"s":"apns","e":"1234abcd"}',
    )!;
    expect(legacy.eventHash, '1234abcd');
    expect(legacy.recordId, isNull);
    expect(legacy.eventHash128, isNull);
    final bad = PushJournalEntry.tryParse(
      jsonEncode({
        't': 1,
        's': 'local',
        'id': 'имя человека',
        'e128': 'abc',
        'a128': 12,
        'target128': ['секрет'],
        'kind': 'futureMedia',
        'rel': 'futureRelation',
        'src': 'futureSource',
      }),
    )!;
    expect(bad.recordId, isNull);
    expect(bad.eventHash128, isNull);
    expect(bad.accountHash128, isNull);
    expect(bad.relationTargetHash128, isNull);
    expect(bad.mediaKind, PushMediaKind.unknown);
    expect(bad.relationKind, PushRelationKind.unknown);
    expect(bad.source, isNull);
    const unsafe = PushJournalEntry(
      timeMs: 1,
      stage: PushStage.local,
      recordId: 'private-id',
      eventHash128: 'private-event',
      accountHash128: 'private-account',
      relationTargetHash128: 'private-target',
      eventHash: 'private-old-event',
      roomHash: 'private-room',
    );
    expect(unsafe.toJson(), {'t': 1, 's': 'local'});
    journal.recordNative({
      'stage': 'native',
      'eventId': r'$натив',
      'kind': 'voice',
    });
    expect(journal.entries.single.eventHash128, pushAckHash(r'$натив'));
    expect(journal.entries.single.source, PushObservationSource.native);
    expect(journal.entries.single.mediaKind, isNull);
    expect(journal.entries.single.accountHash128, isNull);
  });

  // AC:RL-macos-push-collision-observability/10
  test(
    'кольцо и pending ограничены; coverage описывает точный byte-tail',
    () async {
      for (var i = 0; i < PushJournal.maxEntries + 7; i++) {
        journal.record(
          PushStage.apns,
          eventId: '\$событие🔥$i',
          accountName: 'Аккаунт🌍',
          now: DateTime.fromMillisecondsSinceEpoch(i),
        );
      }
      final snapshot = journal.entries;
      expect(snapshot, hasLength(PushJournal.maxEntries));
      final coverage = journal.exportCoverage(snapshot, 24 * 1024);
      final tail = PushJournal.tail(snapshot, 24 * 1024);
      expect(utf8.encode(tail).length, lessThanOrEqualTo(24 * 1024));
      final exported = tail
          .split('\n')
          .map((line) => PushJournalEntry.tryParse(line)!)
          .toList();
      expect(coverage['exported_entries'], exported.length);
      expect(coverage['retained_entries'], PushJournal.maxEntries);
      expect(coverage['tail_truncated'], isTrue);
      expect(coverage['first_exported_ms'], exported.first.timeMs);
      expect(coverage['last_exported_ms'], exported.last.timeMs);
      expect(coverage['ring_evictions_since_start'], 7);
      expect(coverage['pending_evictions_since_start'], 7);
      expect(coverage['counter_scope'], 'process_lifetime');
      expect(coverage['crash_tail'], 'best_effort_5s');
      await journal.init();
      journal.flush();
      final lines = File('${dir.path}/push_journal.jsonl').readAsLinesSync();
      expect(lines, hasLength(PushJournal.maxEntries));
      expect(PushJournalEntry.tryParse(lines.first)!.timeMs, 7);
      expect(journal.exportCoverage(snapshot, 0)['exported_entries'], 0);
      expect(
        journal.exportCoverage(snapshot, 0).containsKey('first_exported_ms'),
        isFalse,
      );
      journal.resetForTest();
      final empty = journal.exportCoverage(journal.entries, 24 * 1024);
      expect(empty['ring_evictions_since_start'], 0);
      expect(empty['pending_evictions_since_start'], 0);
      expect(empty['tail_truncated'], isFalse);
      expect(empty.containsKey('last_exported_ms'), isFalse);
    },
  );

  // AC:RL-macos-push-collision-observability/11
  test(
    'ошибка записи сохраняет pending; повтор записывает весь хвост',
    () async {
      await journal.init();
      final path = '${dir.path}/push_journal.jsonl';
      Directory(path).createSync();
      journal.record(PushStage.local, eventId: r'$before-failure');
      final firstId = journal.entries.single.recordId;
      journal.flush();
      expect(
        journal.exportCoverage(
          journal.entries,
          24000,
        )['persistence_failures_since_start'],
        1,
      );
      journal.record(PushStage.apns, eventId: r'$after-failure');
      Directory(path).deleteSync();
      journal.flush();
      journal.flush();
      final entries = File(
        path,
      ).readAsLinesSync().map(PushJournalEntry.tryParse).toList();
      expect(entries, hasLength(2));
      expect(entries.first!.recordId, firstId);
      expect(entries.last!.eventHash128, pushAckHash(r'$after-failure'));
      journal.resetForTest();
      expect(
        journal.exportCoverage([], 24000)['persistence_failures_since_start'],
        0,
      );
    },
  );

  // AC:RL-macos-push-collision-observability/11
  test(
    'record во время await чтения init сохраняется; init имеет одного писателя',
    () async {
      final realFile = File('${dir.path}/push_journal.jsonl');
      realFile.writeAsStringSync('{"t":0,"s":"sleep"}\n');
      final delayed = _DelayedReadFile(realFile);
      await IOOverrides.runZoned(() async {
        journal.record(PushStage.apns, eventId: r'$before');
        final init = journal.init();
        await delayed.started.future;
        final concurrentInit = journal.init();
        journal.record(PushStage.local, eventId: r'$during');
        delayed.release.complete();
        await Future.wait([init, concurrentInit]);
        journal.record(PushStage.retract, eventId: r'$after');
        journal.flush();
      }, createFile: (_) => delayed);
      final entries = realFile
          .readAsLinesSync()
          .map(PushJournalEntry.tryParse)
          .toList();
      expect(entries, hasLength(4));
      expect(entries.map((e) => e!.stage), [
        PushStage.sleep,
        PushStage.apns,
        PushStage.local,
        PushStage.retract,
      ]);
      expect(entries[2]!.eventHash128, pushAckHash(r'$during'));
      expect(
        entries.map((e) => e!.toJson()),
        journal.entries.map((e) => e.toJson()),
      );
    },
  );

  // AC:RL-macos-push-collision-observability/11
  test('ошибка init разрешает повтор и не теряет раннюю запись', () async {
    final path = '${dir.path}/push_journal.jsonl';
    final file = File(path)..writeAsStringSync('');
    final delayed = _DelayedReadFile(file);
    journal.record(PushStage.apns, eventId: r'$early');
    await IOOverrides.runZoned(() async {
      final init = journal.init();
      await delayed.started.future;
      delayed.release.completeError(const FileSystemException('read failed'));
      await init;
    }, createFile: (_) => delayed);
    expect(
      journal.exportCoverage(
        journal.entries,
        24000,
      )['persistence_failures_since_start'],
      1,
    );
    await journal.init();
    journal.flush();
    final lines = File(path).readAsLinesSync();
    expect(lines, hasLength(1));
    expect(
      PushJournalEntry.tryParse(lines.single)!.eventHash128,
      pushAckHash(r'$early'),
    );
  });

  // AC:RL-macos-push-collision-observability/11
  test('компакция большого файла не дублирует ранние записи', () async {
    final file = File('${dir.path}/push_journal.jsonl');
    final padding = ' ' * 300;
    file.writeAsStringSync(
      List.generate(2100, (i) => '{"t":$i,"s":"sleep"}$padding\n').join(),
    );
    expect(file.lengthSync(), greaterThan(512 * 1024));
    journal.record(PushStage.apns, eventId: r'$early');
    final id = journal.entries.single.recordId;
    await journal.init();
    journal.flush();
    final entries = file
        .readAsLinesSync()
        .map(PushJournalEntry.tryParse)
        .toList();
    expect(entries, hasLength(PushJournal.maxEntries));
    expect(entries.where((e) => e!.recordId == id), hasLength(1));
    expect(file.lengthSync(), lessThan(512 * 1024));
    journal.resetForTest();
    await journal.init();
    expect(journal.entries.last.recordId, id);
    expect(journal.entries, hasLength(PushJournal.maxEntries));
  });

  // AC:RL-macos-push-collision-observability/10
  test(
    'полные записи соблюдают 512 КБ; потери учитываются ровно один раз',
    () async {
      void recordFull(int i) => journal.record(
        PushStage.collision,
        reason: PushReason.suppressLocal,
        eventId: '\$событие🔥$i',
        roomId: '!комната:$i',
        accountName: 'аккаунт:$i',
        mediaKind: PushMediaKind.voice,
        relationKind: PushRelationKind.reply,
        relationTargetId: '\$цель:$i',
        source: PushObservationSource.localSubmission,
        value: 123456789,
        now: DateTime.fromMillisecondsSinceEpoch(1794787200000 + i),
      );

      for (var i = 0; i < PushJournal.maxEntries; i++) {
        recordFull(i);
      }
      final original = journal.entries;
      expect(
        utf8.encode(PushJournal.tail(original, 10000000)).length,
        greaterThan(512 * 1024),
      );
      await journal.init();
      final file = File('${dir.path}/push_journal.jsonl');
      // Ошибка именно компакции: до успешного IO потери не объявляются,
      // кольцо и pending остаются доступными для повтора.
      Directory(file.path).createSync();
      journal.flush();
      final failed = journal.exportCoverage(journal.entries, 24000);
      expect(journal.entries, hasLength(PushJournal.maxEntries));
      expect(failed['disk_evictions_since_start'], 0);
      expect(failed['ring_evictions_since_start'], 0);
      expect(failed['pending_evictions_since_start'], 0);
      expect(failed['persistence_failures_since_start'], 1);
      Directory(file.path).deleteSync();
      journal.flush();
      expect(file.lengthSync(), lessThanOrEqualTo(512 * 1024));
      final kept = journal.entries.length;
      final lost = PushJournal.maxEntries - kept;
      expect(lost, greaterThan(0));
      final coverage = journal.exportCoverage(journal.entries, 24000);
      expect(coverage['disk_evictions_since_start'], lost);
      expect(coverage['ring_evictions_since_start'], lost);
      expect(coverage['pending_evictions_since_start'], lost);
      expect(
        journal.entries.map((e) => e.recordId),
        original.skip(lost).map((e) => e.recordId),
      );
      final firstDisk = file.readAsStringSync();
      journal.flush();
      expect(file.readAsStringSync(), firstDisk);
      expect(journal.exportCoverage(journal.entries, 24000), coverage);

      // Уже существующий файл ещё укладывается в лимит, но следующий append
      // вывел бы его за предел: компакция должна сработать ДО дописывания.
      for (var i = 0; i < 100; i++) {
        recordFull(PushJournal.maxEntries + i);
      }
      journal.flush();
      expect(file.lengthSync(), lessThanOrEqualTo(512 * 1024));
      final additionalLoss = kept + 100 - journal.entries.length;
      final after = journal.exportCoverage(journal.entries, 24000);
      expect(after['disk_evictions_since_start'], lost + additionalLoss);
      expect(after['ring_evictions_since_start'], lost + additionalLoss);
      // Второй раз вытеснены уже сохранённые записи: pending не потерян.
      expect(after['pending_evictions_since_start'], lost);
      final finalIds = journal.entries.map((e) => e.recordId).toList();
      journal.resetForTest();
      expect(
        journal.exportCoverage([], 24000)['disk_evictions_since_start'],
        0,
      );
      await journal.init();
      expect(journal.entries.map((e) => e.recordId), finalIds);
    },
  );
}
