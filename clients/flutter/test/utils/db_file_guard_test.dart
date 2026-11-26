// Страж реестра регрессии: ledger:RL-db-quarantine-not-delete (см. tests/registry/).
//
// Инвариант: ни один путь открытия локальной БД не удаляет непустой файл
// безвозвратно — он уходит в `<path>.bak-<UTC>` вместе с `-wal`/`-journal`;
// путь `.sqlite` после этого свободен всегда (иначе петля перезапуска), а
// серия пустых сбойных БД не вытесняет настоящую копию.

library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/db_file_guard.dart';

void main() {
  late Directory dir;
  late String path;
  final fixedNow = DateTime.utc(2026, 11, 25, 10, 0, 0);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('db_guard_');
    path = '${dir.path}/liza.sqlite';
  });

  tearDown(() async {
    await Process.run('chmod', ['-R', 'u+w', dir.path]);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> write(String p, String content) =>
      File(p).writeAsString(content);

  List<String> names() =>
      dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  Future<bool> quarantine({
    DateTime? at,
    RenameFile? rename,
    List<DbStorageEvent>? events,
  }) => quarantineDatabaseFiles(
    path,
    now: () => at ?? fixedNow,
    rename: rename ?? (from, to) => File(from).rename(to),
    onEvent: events?.add,
  );

  group('карантин вместо удаления [AC:RL-db-quarantine-not-delete/1]', () {
    test(
      'основной файл переименован, содержимое цело, путь свободен',
      () async {
        await write(path, 'history');
        final events = <DbStorageEvent>[];

        expect(await quarantine(events: events), isTrue);

        expect(File(path).existsSync(), isFalse);
        expect(names(), ['liza.sqlite.bak-20261125T100000']);
        expect(
          await File('$path.bak-20261125T100000').readAsString(),
          'history',
        );
        expect(events, isEmpty);
      },
    );

    test('повтор в ту же секунду не затирает прежнюю копию', () async {
      // Первая крупнее: правило хранения оставит её как самую большую, а
      // вторую — как самую новую; проверяем, что одинаковое время не затирает.
      await write(path, 'first-and-bigger');
      await quarantine();
      await write(path, 'second');
      await quarantine(at: fixedNow.add(const Duration(milliseconds: 7)));

      expect(names(), [
        'liza.sqlite.bak-20261125T100000',
        'liza.sqlite.bak-20261125T100000007',
      ]);
    });
  });

  group('спутники WAL [AC:RL-db-quarantine-not-delete/2]', () {
    final cases = <String, List<String>>{
      'нет спутников': [],
      'только -wal': ['-wal'],
      'только -shm': ['-shm'],
      '-wal и -shm': ['-wal', '-shm'],
      '-journal': ['-journal'],
      'все и обрезок шифрования': ['-wal', '-shm', '-journal', '.encrypted'],
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        await write(path, 'main');
        for (final s in entry.value) {
          await write('$path$s', 'side$s');
        }

        expect(await quarantine(), isTrue);

        final expected = <String>['liza.sqlite.bak-20261125T100000'];
        for (final s in ['-wal', '-journal']) {
          if (entry.value.contains(s)) {
            expected.add('liza.sqlite.bak-20261125T100000$s');
          }
        }
        expect(names(), expected..sort(), reason: '-shm и .encrypted удалены');
        for (final s in ['', '-wal', '-shm', '-journal', '.encrypted']) {
          expect(File('$path$s').existsSync(), isFalse, reason: 'остался $s');
        }
      });
    }
  });

  test('настоящая WAL-БД: копия открывается и строка в ней на месте '
      '[AC:RL-db-quarantine-not-delete/3]', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(path);
    await db.execute('PRAGMA journal_mode=WAL');
    await db.execute('CREATE TABLE t (v TEXT)');
    await db.insert('t', {'v': 'keep-me'});
    await db.close();

    expect(await quarantine(), isTrue);

    final copy = await databaseFactoryFfi.openDatabase(
      '$path.bak-20261125T100000',
    );
    expect(await copy.query('t'), [
      {'v': 'keep-me'},
    ]);
    await copy.close();
  });

  group('отказ переименования [AC:RL-db-quarantine-not-delete/4]', () {
    test('rename падает → файл удалён, путь свободен, событие', () async {
      await write(path, 'main');
      await write('$path-wal', 'wal');
      final events = <DbStorageEvent>[];

      final freed = await quarantine(
        events: events,
        rename: (from, to) async =>
            throw PathAccessException(from, const OSError('locked', 32)),
      );

      expect(freed, isTrue);
      expect(names(), isEmpty);
      expect(events, everyElement(DbStorageEvent.renameFallbackDelete));
    });

    test(
      'не удаётся ни переименовать, ни удалить → false, не бросает',
      () async {
        await write(path, 'main');
        await Process.run('chmod', ['a-w', dir.path]);
        final events = <DbStorageEvent>[];

        final freed = await quarantine(
          events: events,
          rename: (from, to) async =>
              throw PathAccessException(from, const OSError('locked', 32)),
        );

        expect(freed, isFalse);
        expect(File(path).existsSync(), isTrue);
        expect(events.last, DbStorageEvent.pathNotFreed);
      },
    );
  });

  group('хранение копий [AC:RL-db-quarantine-not-delete/5]', () {
    test('пустой файл в карантин не попадает', () async {
      await write(path, '');
      await write('$path-wal', '');

      expect(await quarantine(), isTrue);
      expect(names(), isEmpty);
    });

    test('остаются самый большой и самый новый набор', () async {
      final sizes = [500, 10, 20];
      for (var i = 0; i < sizes.length; i++) {
        await write(path, 'x' * sizes[i]);
        await quarantine(at: fixedNow.add(Duration(minutes: i)));
      }

      expect(names(), [
        'liza.sqlite.bak-20261125T100000',
        'liza.sqlite.bak-20261125T100200',
      ]);
    });

    test('пять пустых сбоев подряд не вытесняют настоящую копию', () async {
      await write(path, 'x' * 1000);
      await quarantine();
      for (var i = 1; i <= 5; i++) {
        await write(path, '');
        await quarantine(at: fixedNow.add(Duration(minutes: i)));
      }

      expect(names(), ['liza.sqlite.bak-20261125T100000']);
    });

    test('старше 30 дней удаляется, включая самый большой', () async {
      await write(path, 'x' * 1000);
      await quarantine();
      await write(path, 'x' * 10);
      await quarantine(at: fixedNow.add(const Duration(days: 1)));
      // Ещё один сбой спустя 40 дней: обе прежние копии устарели.
      await write(path, 'x' * 20);
      await quarantine(at: fixedNow.add(const Duration(days: 41)));

      expect(names(), ['liza.sqlite.bak-20270105T100000']);
    });
  });

  group('копии не живут вечно [AC:RL-db-quarantine-not-delete/12]', () {
    test('выход из аккаунта удаляет все копии со спутниками', () async {
      await write(path, 'x' * 1000);
      await write('$path-wal', 'w');
      await quarantine();
      await write(path, 'x' * 10);
      await quarantine(at: fixedNow.add(const Duration(minutes: 1)));
      await write(path, 'live');
      expect(names().where((n) => n.contains('.bak-')), hasLength(3));

      await deleteQuarantinedDatabases(path);

      expect(names(), ['liza.sqlite']);
    });

    test('старт без нового сбоя чистит копии старше 30 дней', () async {
      await write(path, 'x' * 1000);
      await quarantine();
      await write(path, 'live');

      await pruneQuarantinedDatabases(
        path,
        now: () => fixedNow.add(const Duration(days: 29)),
      );
      expect(names(), ['liza.sqlite', 'liza.sqlite.bak-20261125T100000']);

      await pruneQuarantinedDatabases(
        path,
        now: () => fixedNow.add(const Duration(days: 31)),
      );
      expect(names(), ['liza.sqlite']);
    });

    test('нет каталога — не бросает', () async {
      await deleteQuarantinedDatabases('${dir.path}/nope/liza.sqlite');
      await pruneQuarantinedDatabases('${dir.path}/nope/liza.sqlite');
    });
  });

  group(
    'что делать после ошибки открытия [AC:RL-db-quarantine-not-delete/6]',
    () {
      final cases = <String, (Object, bool, OpenFailureAction)>{
        'PlatformException (Keychain залочен)': (
          PlatformException(code: 'KeychainLocked'),
          true,
          OpenFailureAction.keepPlatform,
        ),
        'SQLCipher не загрузился': (
          StateError(
            'SQLCipher library is not available, please check your dependencies!',
          ),
          true,
          OpenFailureAction.keepCipherUnavailable,
        ),
        'файл не открывается, основной изолят': (
          Exception('file is not a database'),
          true,
          OpenFailureAction.quarantine,
        ),
        'файл не открывается, фоновый изолят': (
          Exception('file is not a database'),
          false,
          OpenFailureAction.keep,
        ),
        'путь уже не освободился': (
          DatabasePathNotFreedException(Exception('x')),
          true,
          OpenFailureAction.keep,
        ),
        'прочий StateError': (
          StateError('other'),
          true,
          OpenFailureAction.quarantine,
        ),
      };
      for (final entry in cases.entries) {
        test(entry.key, () {
          final (error, allow, expected) = entry.value;
          expect(decideOpenFailure(error, allowQuarantine: allow), expected);
        });
      }
    },
  );

  test('имена копий не похожи на живую БД для счётчика Keychain '
      '[AC:RL-db-quarantine-not-delete/7]', () async {
    await write(path, 'main');
    await write('$path-wal', 'wal');
    await write('$path-journal', 'journal');
    await quarantine();
    // cipher.dart `_databaseFileExists` ищет окончание `.sqlite`.
    expect(names().where((n) => n.endsWith('.sqlite')), isEmpty);
  });
}
