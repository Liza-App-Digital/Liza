// ledger:RL-safedb-path-access-guard
//
// Страж: SafeDatabaseApi перехватывает PathNotFoundException И PathAccessException
// (Windows errno 32, файл залочен антивирусом/индексатором) в 4 методах файл-кэша
// и НЕ пробрасывает их в root-zone. Прочие исключения (StateError, Exception)
// ПРОБРАСЫВАЮТСЯ — не заглушаем всё подряд.
//
// Дефект до фикса: только PathNotFoundException перехватывалась; PathAccessException
// всплывала необработанной в root-zone — в логе Петра (Windows) ~99% строк
// составлял шторм deleteOldFiles по общему %TEMP%.
//
// AC:RL-safedb-path-access-guard/1 — PathNotFoundException → graceful
// AC:RL-safedb-path-access-guard/2 — PathAccessException   → graceful (red-proof)
// AC:RL-safedb-path-access-guard/3 — прочее исключение     → пробрасывается

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/safe_database_api.dart';

// ---------------------------------------------------------------------------
// Минимальный фейк DatabaseApi — бросает заданное исключение из 4 методов
// файл-кэша; все остальные — noSuchMethod (тест их не вызывает).
// ---------------------------------------------------------------------------

class _ThrowingDb extends DatabaseApi {
  final Object _exception;

  _ThrowingDb(this._exception);

  @override
  int get maxFileSize => 1 * 1000 * 1000;

  @override
  bool get supportsFileStoring => true;

  @override
  Future<void> deleteOldFiles(int savedAt) async => throw _exception;

  @override
  Future<bool> deleteFile(Uri mxcUri) async => throw _exception;

  @override
  Future<Uint8List?> getFile(Uri mxcUri) async => throw _exception;

  @override
  Future storeFile(Uri mxcUri, Uint8List bytes, int time) async =>
      throw _exception;

  // ignore: avoid_returning_null_for_void
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ---------------------------------------------------------------------------
// Фабрики тестовых исключений
// ---------------------------------------------------------------------------

PathNotFoundException _makeNotFound() => PathNotFoundException(
      '/cache/file',
      OSError('No such file or directory', 2),
      '/cache/file',
    );

PathAccessException _makeAccessDenied() => PathAccessException(
      '/cache/file',
      OSError('Sharing violation', 32),
      '/cache/file',
    );

StateError _makeStateError() => StateError('unexpected state');

// ---------------------------------------------------------------------------
// Тесты
// ---------------------------------------------------------------------------

void main() {
  final mxc = Uri.parse('mxc://example.org/abc123');
  final bytes = Uint8List.fromList([1, 2, 3]);

  // ---- AC-1: PathNotFoundException → graceful --------------------------------

  group(
    'AC:RL-safedb-path-access-guard/1 — PathNotFoundException → graceful',
    () {
      late SafeDatabaseApi sut;
      setUp(() => sut = SafeDatabaseApi(_ThrowingDb(_makeNotFound())));

      test('getFile → null (cache-miss)', () async {
        final result = await sut.getFile(mxc);
        expect(result, isNull);
      });

      test('deleteFile → false', () async {
        final result = await sut.deleteFile(mxc);
        expect(result, isFalse);
      });

      test('deleteOldFiles → возвращает без throw', () async {
        await expectLater(sut.deleteOldFiles(0), completes);
      });

      test('storeFile → возвращает без throw', () async {
        await expectLater(sut.storeFile(mxc, bytes, 0), completes);
      });
    },
  );

  // ---- AC-2: PathAccessException → graceful (ловит регресс «до фикса») -------

  group(
    'AC:RL-safedb-path-access-guard/2 — PathAccessException → graceful',
    () {
      late SafeDatabaseApi sut;
      setUp(() => sut = SafeDatabaseApi(_ThrowingDb(_makeAccessDenied())));

      test('getFile → null (Windows: файл залочен)', () async {
        final result = await sut.getFile(mxc);
        expect(result, isNull);
      });

      test('deleteFile → false (Windows: файл залочен)', () async {
        final result = await sut.deleteFile(mxc);
        expect(result, isFalse);
      });

      test('deleteOldFiles → возвращает без throw (Windows: файл залочен)',
          () async {
        await expectLater(sut.deleteOldFiles(0), completes);
      });

      test('storeFile → возвращает без throw (Windows: файл залочен)',
          () async {
        await expectLater(sut.storeFile(mxc, bytes, 0), completes);
      });
    },
  );

  // ---- AC-3: прочее исключение → ПРОБРАСЫВАЕТСЯ ------------------------------

  group(
    'AC:RL-safedb-path-access-guard/3 — прочее исключение пробрасывается',
    () {
      late SafeDatabaseApi sut;
      setUp(() => sut = SafeDatabaseApi(_ThrowingDb(_makeStateError())));

      test('getFile → пробрасывает StateError', () async {
        await expectLater(sut.getFile(mxc), throwsStateError);
      });

      test('deleteFile → пробрасывает StateError', () async {
        await expectLater(sut.deleteFile(mxc), throwsStateError);
      });

      test('deleteOldFiles → пробрасывает StateError', () async {
        await expectLater(sut.deleteOldFiles(0), throwsStateError);
      });

      test('storeFile → пробрасывает StateError', () async {
        await expectLater(sut.storeFile(mxc, bytes, 0), throwsStateError);
      });
    },
  );

  // ---- AC-3 дополнение: обычный Exception тоже пробрасывается ---------------

  group(
    'AC:RL-safedb-path-access-guard/3 (Exception) — пробрасывается',
    () {
      late SafeDatabaseApi sut;
      setUp(() => sut =
          SafeDatabaseApi(_ThrowingDb(Exception('unexpected db error'))));

      test('getFile → пробрасывает Exception', () async {
        await expectLater(sut.getFile(mxc), throwsException);
      });

      test('deleteFile → пробрасывает Exception', () async {
        await expectLater(sut.deleteFile(mxc), throwsException);
      });

      test('deleteOldFiles → пробрасывает Exception', () async {
        await expectLater(sut.deleteOldFiles(0), throwsException);
      });

      test('storeFile → пробрасывает Exception', () async {
        await expectLater(sut.storeFile(mxc, bytes, 0), throwsException);
      });
    },
  );
}
