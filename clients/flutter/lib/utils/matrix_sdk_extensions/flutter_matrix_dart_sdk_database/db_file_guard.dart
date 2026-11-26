import 'dart:io';

import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';

/// Причины событий хранилища. Закрытый перечень: значение уходит в заголовок
/// алёрта, поэтому туда не попадают пути, имена клиентов и тексты ошибок.
enum DbStorageEvent {
  quarantineOpen('quarantine-open'),
  quarantineEncrypt('quarantine-encrypt'),
  quarantineNoKeystore('quarantine-nokeystore'),
  cipherUnavailable('cipher-unavailable'),
  platformException('platform-exception'),
  renameFallbackDelete('rename-fallback-delete'),
  pathNotFreed('path-not-freed');

  const DbStorageEvent(this.wire);
  final String wire;
}

/// Путь к файлу БД не удалось освободить (Windows держит файл). Бросаем явно:
/// тихий проход дал бы ту же ошибку открытия на каждом запуске.
class DatabasePathNotFreedException implements Exception {
  DatabasePathNotFreedException(this.cause);
  final Object cause;

  @override
  String toString() => 'DatabasePathNotFreedException(cause: $cause)';
}

enum OpenFailureAction {
  /// Временная ошибка платформы (Keychain залочен) — файл исправен.
  keepPlatform,

  /// Не загрузился SQLCipher — файл исправен, свежая БД упадёт так же.
  keepCipherUnavailable,

  /// Файл не трогаем без метрики: фоновый изолят или уже разобранный путь.
  keep,

  /// Файл не открывается — уводим в карантин, чтобы следующий старт был чистым.
  quarantine,
}

/// Что делать с файлом БД после ошибки открытия. [allowQuarantine] = false в
/// фоновых изолятах: основной изолят может держать файл открытым.
OpenFailureAction decideOpenFailure(
  Object error, {
  required bool allowQuarantine,
}) {
  if (error is PlatformException) return OpenFailureAction.keepPlatform;
  if (isCipherUnavailableError(error)) {
    return OpenFailureAction.keepCipherUnavailable;
  }
  if (error is DatabasePathNotFreedException || !allowQuarantine) {
    return OpenFailureAction.keep;
  }
  return OpenFailureAction.quarantine;
}

/// `applyPragmaKey` SDK бросает это, когда `PRAGMA cipher_version` пуст.
bool isCipherUnavailableError(Object e) =>
    e is StateError && e.message.contains('SQLCipher library is not available');

typedef RenameFile = Future<void> Function(String from, String to);

const Duration quarantineMaxAge = Duration(days: 30);

const String _bakMarker = '.bak-';

/// Спутники, в которых могут лежать закоммиченные данные: их переносим вместе
/// с основным файлом. `-shm` — производный индекс, его удаляем.
const List<String> _dataSidecars = ['-wal', '-journal'];
const List<String> _disposableSidecars = ['-shm', '.encrypted'];

Future<void> _defaultRename(String from, String to) async {
  await File(from).rename(to);
}

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final u = t.toUtc();
  return '${u.year}${two(u.month)}${two(u.day)}T'
      '${two(u.hour)}${two(u.minute)}${two(u.second)}';
}

/// Убирает файлы БД с пути [path], ничего не уничтожая без нужды.
///
/// Непустой основной файл и его `-wal`/`-journal` переименовываются в
/// `<path>.bak-<UTC>`; `-shm` и обрезок шифрования удаляются. Не вышло
/// переименовать — файл удаляется: чужой `-wal` рядом со свежей БД хуже потери
/// хвоста. Возвращает `true`, если у [path] больше ничего не осталось.
/// Никогда не бросает: вызывается из обработчика ошибки открытия.
Future<bool> quarantineDatabaseFiles(
  String path, {
  RenameFile rename = _defaultRename,
  DateTime Function() now = DateTime.now,
  void Function(DbStorageEvent event)? onEvent,
}) async {
  var freed = true;
  try {
    final main = File(path);
    final mainSize = await main.exists() ? await main.length() : 0;

    if (mainSize == 0) {
      // Пустую БД хранить незачем, а серия таких копий вытеснила бы настоящую.
      for (final suffix in ['', ..._dataSidecars, ..._disposableSidecars]) {
        if (!await _deleteIfExists('$path$suffix')) freed = false;
      }
    } else {
      final t = now();
      var target = '$path$_bakMarker${_stamp(t)}';
      if (await _anyExists(target)) {
        target = '$target${t.millisecond.toString().padLeft(3, '0')}';
      }
      // Спутники с данными — первыми: если основной файл уедет, а `-wal`
      // останется, SQLite применит его к следующей, чужой БД.
      for (final suffix in [..._dataSidecars, '']) {
        final from = '$path$suffix';
        if (!await File(from).exists()) continue;
        try {
          await rename(from, '$target$suffix');
        } catch (e) {
          Logs().w('DB quarantine: rename failed, deleting instead', e);
          onEvent?.call(DbStorageEvent.renameFallbackDelete);
          if (!await _deleteIfExists(from)) freed = false;
        }
      }
      for (final suffix in _disposableSidecars) {
        if (!await _deleteIfExists('$path$suffix')) freed = false;
      }
      if (await File(target).exists()) {
        Logs().w(
          'DB quarantined to ${target.split(Platform.pathSeparator).last}',
        );
      }
    }

    await _pruneQuarantine(path, now());
  } catch (e, s) {
    Logs().e('DB quarantine failed unexpectedly', e, s);
  }

  try {
    for (final suffix in ['', ..._dataSidecars, ..._disposableSidecars]) {
      if (await File('$path$suffix').exists()) freed = false;
    }
  } catch (_) {
    freed = false;
  }
  if (!freed) onEvent?.call(DbStorageEvent.pathNotFreed);
  return freed;
}

DateTime? _parseStamp(String raw) {
  if (raw.length < 15) return null;
  final m = RegExp(
    r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\d{3})?',
  ).firstMatch(raw);
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i) ?? '0');
  return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6), g(7));
}

Future<bool> _anyExists(String base) async {
  for (final suffix in ['', ..._dataSidecars]) {
    if (await File('$base$suffix').exists()) return true;
  }
  return false;
}

Future<bool> _deleteIfExists(String p) async {
  final f = File(p);
  try {
    if (await f.exists()) await f.delete();
    return true;
  } catch (e) {
    Logs().w('DB quarantine: cannot delete a database file', e);
    return false;
  }
}

class _QuarantineSet {
  _QuarantineSet(this.base, this.size, this.quarantinedAt);
  final String base;
  final int size;
  final DateTime quarantinedAt;
}

/// Чистит копии на старте основного изолята: без нового сбоя иначе ничего не
/// истекало бы. Никогда не бросает.
Future<void> pruneQuarantinedDatabases(
  String path, {
  DateTime Function() now = DateTime.now,
}) async {
  try {
    await _pruneQuarantine(path, now());
  } catch (e) {
    Logs().w('DB quarantine: prune failed', e);
  }
}

/// Выход из аккаунта: копия хранит историю чатов (в ветке без Keystore — без
/// шифрования), после логаута держать её незачем. Никогда не бросает.
Future<void> deleteQuarantinedDatabases(String path) async {
  try {
    for (final set in await _listQuarantine(path)) {
      await _deleteSet(set.base);
    }
  } catch (e) {
    Logs().w('DB quarantine: delete on logout failed', e);
  }
}

Future<List<_QuarantineSet>> _listQuarantine(String path) async {
  final dir = File(path).parent;
  final prefix = '${File(path).uri.pathSegments.last}$_bakMarker';
  final sets = <_QuarantineSet>[];
  if (!await dir.exists()) return sets;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (!name.startsWith(prefix)) continue;
    if (_dataSidecars.any(name.endsWith)) continue;
    // Время — из имени, а не mtime: rename сохраняет mtime исходного файла.
    final quarantinedAt = _parseStamp(name.substring(prefix.length));
    if (quarantinedAt == null) continue;
    sets.add(_QuarantineSet(entity.path, await entity.length(), quarantinedAt));
  }
  return sets;
}

Future<void> _deleteSet(String base) async {
  for (final suffix in ['', ..._dataSidecars]) {
    await _deleteIfExists('$base$suffix');
  }
}

/// Всё старше [quarantineMaxAge] удаляется; из остального хранятся набор с
/// самым большим основным файлом (скорее всего — настоящая история) и самый
/// новый.
Future<void> _pruneQuarantine(String path, DateTime now) async {
  final all = await _listQuarantine(path);
  final sets = <_QuarantineSet>[];
  for (final set in all) {
    if (now.toUtc().difference(set.quarantinedAt) > quarantineMaxAge) {
      await _deleteSet(set.base);
    } else {
      sets.add(set);
    }
  }
  if (sets.isEmpty) return;

  final keep = <String>{};
  sets.sort((a, b) => b.size.compareTo(a.size));
  keep.add(sets.first.base);
  final newest = [...sets]
    ..sort((a, b) => b.quarantinedAt.compareTo(a.quarantinedAt));
  keep.add(newest.first.base);

  for (final set in sets) {
    if (!keep.contains(set.base)) await _deleteSet(set.base);
  }
}
