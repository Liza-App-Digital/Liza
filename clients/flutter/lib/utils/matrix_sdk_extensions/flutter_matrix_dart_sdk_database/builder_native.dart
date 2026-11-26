import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/platform_infos.dart';
import 'cipher.dart';
import 'db_file_guard.dart';
import 'safe_database_api.dart';

import 'sqlcipher_stub.dart'
    if (dart.library.io) 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';

/// В фоновых изолятах мониторинг не поднят — там событие остаётся только в логе.
void _onDbStorageEvent(DbStorageEvent event) {
  Logs().w('DB storage event: ${event.wire}');
  Monitoring.reportDbStorage(event.wire);
}

/// [allowQuarantine] = false в фоновых изолятах (пуш, тап по уведомлению):
/// основной изолят может держать БД открытой, и разбирать файлы из-под него
/// нельзя. Сбойную БД уберёт следующий запуск основного изолята.
Future<DatabaseApi> flutterMatrixSdkDatabaseBuilder(
  String clientName, {
  bool allowQuarantine = true,
}) async {
  try {
    final database = await _constructDatabase(
      clientName,
      allowQuarantine: allowQuarantine,
    );
    try {
      await database.open();
    } catch (_) {
      await database.close().catchError((_) {});
      rethrow;
    }
    final path = await _getDatabasePath(clientName);
    if (allowQuarantine) await pruneQuarantinedDatabases(path);
    return SafeDatabaseApi(
      database,
      onWiped: () => deleteQuarantinedDatabases(path),
    );
  } catch (e, s) {
    Logs().wtf('Unable to construct database!', e, s);
    switch (decideOpenFailure(e, allowQuarantine: allowQuarantine)) {
      case OpenFailureAction.keepPlatform:
        _onDbStorageEvent(DbStorageEvent.platformException);
      case OpenFailureAction.keepCipherUnavailable:
        _onDbStorageEvent(DbStorageEvent.cipherUnavailable);
      case OpenFailureAction.keep:
        break;
      case OpenFailureAction.quarantine:
        await _quarantineOrThrow(
          await _getDatabasePath(clientName),
          DbStorageEvent.quarantineOpen,
          e,
        );
    }
    rethrow;
  }
}

Future<void> _quarantineOrThrow(
  String path,
  DbStorageEvent reason,
  Object cause,
) async {
  _onDbStorageEvent(reason);
  final freed = await quarantineDatabaseFiles(path, onEvent: _onDbStorageEvent);
  if (!freed) throw DatabasePathNotFreedException(cause);
}

Future<MatrixSdkDatabase> _constructDatabase(
  String clientName, {
  required bool allowQuarantine,
}) async {
  final path = await _getDatabasePath(clientName);
  String? cipher;

  try {
    cipher = await getDatabaseCipher();
  } on MissingPluginException catch (e, s) {
    Logs().e('Platform has no secure storage, quarantining database', e, s);
    if (!allowQuarantine) rethrow;
    await _quarantineOrThrow(path, DbStorageEvent.quarantineNoKeystore, e);
    const FlutterSecureStorage()
        .delete(key: 'database_password')
        .catchError((_) {});
    cipher = await getDatabaseCipher();
  } on PlatformException {
    rethrow;
  }

  Directory? fileStorageLocation;
  try {
    final tmp = await getTemporaryDirectory();
    // ⚠️ SDK `deleteOldFiles` листает ВЕСЬ `fileStorageLocation` и удаляет
    // всё старше 30 дней БЕЗ фильтра имён (database_file_storage_io.dart).
    // Если отдать корень `getTemporaryDirectory()` (на Windows — общий
    // `%TEMP%`), клиент листает и пытается удалять ЧУЖИЕ файлы (Windows Fax,
    // чужие `.tmp`) → шторм `PathAccessException` + удаление чужого + SDK
    // съедает наши `liza_video_posters`/`liza_video_prefetch`. Изолируем
    // кэш SDK в собственный подкаталог — тогда `deleteOldFiles` трогает
    // только свои файлы. Миграция старого кэша не нужна: temp самочистится ОС.
    try {
      final sub = Directory('${tmp.path}/liza_media_cache');
      await sub.create(recursive: true);
      fileStorageLocation = sub;
    } on PathAccessException catch (e) {
      // Каталог залочен/readonly (iOS background-purge, Windows lock) —
      // деградируем к базовому temp, но НЕ падаем в database-clear диалог.
      Logs().w(
        'Cannot create media cache subdir, falling back to temp root',
        e,
      );
      fileStorageLocation = tmp;
    }
  } on MissingPlatformDirectoryException catch (_) {
    Logs().w(
      'No temporary directory for file cache available on this platform.',
    );
  }

  // fix dlopen for old Android
  await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();
  // import the SQLite / SQLCipher shared objects / dynamic libraries
  final factory = createDatabaseFactoryFfi(ffiInit: _ffiInit);

  // required for [getDatabasesPath]
  databaseFactory = factory;

  // migrate from potential previous SQLite database path to current one
  await _migrateLegacyLocation(path, clientName);

  // in case we got a cipher, we use the encryption helper
  // to manage SQLite encryption
  final helper = cipher == null
      ? null
      : SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);

  // check whether the DB is already encrypted and otherwise do so
  try {
    await helper?.ensureDatabaseFileEncrypted();
  } catch (e, s) {
    Logs().w(
      'Database file appears corrupted, quarantining and recreating',
      e,
      s,
    );
    // Без SQLCipher / при залоченном Keychain файл исправен: решение и
    // событие — во внешнем catch, как для ошибки open().
    if (decideOpenFailure(e, allowQuarantine: allowQuarantine) !=
        OpenFailureAction.quarantine) {
      rethrow;
    }
    await _quarantineOrThrow(path, DbStorageEvent.quarantineEncrypt, e);
    await helper?.ensureDatabaseFileEncrypted();
  }

  final database = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onConfigure: (db) async {
        await helper?.applyPragmaKey(db);
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA busy_timeout=5000');
      },
    ),
  );

  try {
    return await MatrixSdkDatabase.init(
      clientName,
      database: database,
      maxFileSize: 1000 * 1000 * 10,
      fileStorageLocation: fileStorageLocation?.uri,
      deleteFilesAfterDuration: const Duration(days: 30),
    );
  } catch (_) {
    // init() сам зовёт open(); при его падении соединение остаётся открытым,
    // и на Windows файл нельзя ни переименовать, ни удалить.
    await database.close().catchError((_) {});
    rethrow;
  }
}

Future<String> _getDatabasePath(String clientName) async {
  final databaseDirectory = PlatformInfos.isIOS || PlatformInfos.isMacOS
      ? await getLibraryDirectory()
      : await getApplicationSupportDirectory();

  return join(databaseDirectory.path, '$clientName.sqlite');
}

Future<void> _migrateLegacyLocation(
  String sqlFilePath,
  String clientName,
) async {
  final oldPath = PlatformInfos.isDesktop
      ? (await getApplicationSupportDirectory()).path
      : await getDatabasesPath();

  final oldFilePath = join(oldPath, clientName);
  if (oldFilePath == sqlFilePath) return;

  final maybeOldFile = File(oldFilePath);
  if (await maybeOldFile.exists()) {
    Logs().i(
      'Migrate legacy location for database from "$oldFilePath" to "$sqlFilePath"',
    );
    await maybeOldFile.copy(sqlFilePath);
    await maybeOldFile.delete();
  }
}

/// Custom FFI init that fixes the DLL name mismatch on Windows.
/// `sqlcipher_flutter_libs` bundles `sqlite3.dll` but the Matrix SDK's
/// default [SQfLiteEncryptionHelper.ffiInit] tries to open `libsqlcipher.dll`.
///
/// На macOS дефолтный matrix-путь открывает фреймворк-обёртку
/// `sqlcipher_flutter_libs.framework`, в которой нет sqlite3-символов. FFI
/// тогда резолвит `sqlite3_*` на системный `/usr/lib/libsqlite3.dylib` (без
/// SQLCipher), и `PRAGMA cipher_version` возвращает пусто. Открываем сам
/// `SQLCipher.framework`, где cipher-символы реально есть.
void _ffiInit() {
  if (Platform.isWindows) {
    open.overrideFor(OperatingSystem.windows, () {
      return DynamicLibrary.open('sqlite3.dll');
    });
  } else if (Platform.isMacOS) {
    open.overrideFor(
      OperatingSystem.macOS,
      () =>
          DynamicLibrary.open('SQLCipher.framework/Versions/Current/SQLCipher'),
    );
  } else {
    SQfLiteEncryptionHelper.ffiInit();
  }
}
