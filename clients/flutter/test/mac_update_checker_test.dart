// ledger:RL-macos-stale-process-update
// AC:RL-macos-stale-process-update/1 AC:RL-macos-stale-process-update/2
// AC:RL-macos-stale-process-update/3 AC:RL-macos-stale-process-update/4
// AC:RL-macos-stale-process-update/5 AC:RL-macos-stale-process-update/11
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/mac_update_checker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> reports;
  late int diskReads;
  setUp(() {
    reports = [];
    diskReads = 0;
  });

  MacUpdateChecker make(
    Future<String?> Function() disk, {
    String running = '3807',
    bool enabled = true,
    DateTime Function()? now,
  }) => MacUpdateChecker(
    enabled: enabled,
    readDiskBuild: () {
      diskReads++;
      return disk();
    },
    readRunningBuild: () async => running,
    now: now,
    onStale: (r, d) => reports.add('running=$r disk=$d'),
  );

  group('сравнение диск ↔ процесс', () {
    for (final (name, disk) in [('новее', '3814'), ('откат', '3790')]) {
      test(
        'диск $name процесса → плашка + одно событие [stale-build]',
        () async {
          final c = make(() async => disk);
          addTearDown(c.dispose);
          await c.check(force: true);
          expect(c.updateAvailable.value, isTrue);
          expect(reports, ['running=3807 disk=$disk']);
          await c.check(force: true);
          expect(reports, hasLength(1), reason: 'событие одно на процесс');
        },
      );
    }

    test('номера равны → плашки нет', () async {
      final c = make(() async => '3807');
      addTearDown(c.dispose);
      await c.check(force: true);
      expect(c.updateAvailable.value, isFalse);
      expect(reports, isEmpty);
    });

    final failures = <String, Future<String?> Function()>{
      'null': () async => null,
      'пустая строка': () async => '',
      'MissingPluginException': () => throw MissingPluginException(),
      'PlatformException': () => throw PlatformException(code: 'x'),
      'таймаут': () => Completer<String?>().future,
    };
    failures.forEach((name, disk) {
      test('$name → плашки нет, без исключения', () {
        fakeAsync((async) {
          final c = make(disk);
          c.check(force: true);
          async.elapse(const Duration(seconds: 6));
          expect(c.updateAvailable.value, isFalse);
          expect(reports, isEmpty);
          c.dispose();
        });
      });
    });
  });

  test('выключен (не macOS release) → канал не вызывается', () async {
    final c = make(() async => '3814', enabled: false);
    addTearDown(c.dispose);
    c.start();
    await c.check(force: true);
    expect(diskReads, 0);
    expect(c.isPolling, isFalse);
    expect(c.updateAvailable.value, isFalse);
  });

  test(
    'расписание: старт сразу, таймер, троттл resumed, стоп после находки',
    () {
      fakeAsync((async) {
        var disk = '3807';
        var clock = DateTime(2026, 11, 24);
        final c = make(() async => disk, now: () => clock);
        c.start();
        c.start();
        async.flushMicrotasks();
        expect(
          diskReads,
          1,
          reason: 'проверка сразу, повторный start не дублирует',
        );

        clock = clock.add(const Duration(minutes: 5));
        c.check();
        async.flushMicrotasks();
        expect(diskReads, 1, reason: 'resumed внутри 15 мин троттлится');

        clock = clock.add(MacUpdateChecker.pollInterval);
        async.elapse(MacUpdateChecker.pollInterval);
        expect(diskReads, 2, reason: 'таймер проверяет без resumed');

        disk = '3814';
        clock = clock.add(MacUpdateChecker.pollInterval);
        async.elapse(MacUpdateChecker.pollInterval);
        expect(c.updateAvailable.value, isTrue);
        expect(c.isPolling, isFalse, reason: 'после находки опрос остановлен');

        async.elapse(MacUpdateChecker.pollInterval * 3);
        expect(diskReads, 3);
        c.dispose();
      });
    },
  );

  test('dispose во время чтения не пишет в закрытый notifier', () async {
    final pending = Completer<String?>();
    final c = make(() => pending.future);
    final f = c.check(force: true);
    c.dispose();
    pending.complete('3814');
    await f;
    expect(reports, isEmpty);
  });
}
