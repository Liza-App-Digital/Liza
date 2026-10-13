import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;

import 'package:liza/utils/matrix_sdk_extensions/matrix_file_extension.dart';

void main() {
  // Фиксированное время → детерминированный timestamp «20260710_153000».
  final now = DateTime(2026, 7, 10, 15, 30, 0);
  final bytes = Uint8List(0);

  // Реальные magic-байты форматов для проверки сниффинга по содержимому.
  final pngBytes =
      Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final jpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
  // BMP: сигнатура «BM». package:mime её НЕ знает по содержимому — ловим сами.
  final bmpBytes = Uint8List.fromList([0x42, 0x4D, 0xCE, 0x47, 0x14, 0x00]);

  // ledger:RL-save-filename-fallback
  group('safeSaveFileName', () {
    test('пустое имя изображения → image_<ts> с расширением из mime', () {
      final file =
          MatrixImageFile(bytes: bytes, name: '', mimeType: 'image/jpeg');
      expect(safeSaveFileName(file, now: now), 'image_20260710_153000.jpg');
    });

    test('имя «.jpg» (пустой base) → генерируем полное имя', () {
      final file =
          MatrixFile(bytes: bytes, name: '.jpg', mimeType: 'image/jpeg');
      expect(safeSaveFileName(file, now: now), 'image_20260710_153000.jpg');
    });

    test('имя без расширения → добавляем расширение из mime', () {
      final file = MatrixFile(
        bytes: bytes,
        name: 'contract',
        mimeType: 'application/pdf',
      );
      expect(safeSaveFileName(file, now: now), 'contract.pdf');
    });

    test('корректное имя с кириллицей остаётся как есть', () {
      final file =
          MatrixImageFile(bytes: bytes, name: 'Отчёт.png', mimeType: 'image/png');
      expect(safeSaveFileName(file, now: now), 'Отчёт.png');
    });

    test('пустое имя видео → video_<ts>.mp4', () {
      final file =
          MatrixVideoFile(bytes: bytes, name: '', mimeType: 'video/mp4');
      expect(safeSaveFileName(file, now: now), 'video_20260710_153000.mp4');
    });

    test('пустое имя аудио → audio_<ts>.<ext>', () {
      final file =
          MatrixAudioFile(bytes: bytes, name: '', mimeType: 'audio/mp4');
      expect(safeSaveFileName(file, now: now), 'audio_20260710_153000.m4a');
    });

    test('path-traversal обрезается до basename', () {
      // MatrixFile сам режет по «/», проверяем что расширение всё равно есть.
      final file = MatrixFile(
        bytes: bytes,
        name: '../../secret',
        mimeType: 'application/octet-stream',
      );
      // octet-stream → расширения нет, но имя непустое и без падения.
      expect(safeSaveFileName(file, now: now), 'secret');
    });

    test('двойное расширение сохраняется как есть', () {
      final file = MatrixFile(
        bytes: bytes,
        name: 'archive.tar.gz',
        mimeType: 'application/gzip',
      );
      expect(safeSaveFileName(file, now: now), 'archive.tar.gz');
    });

    test('пустое имя + неизвестный mime → file_<ts> без расширения', () {
      final file = MatrixFile(
        bytes: bytes,
        name: '',
        mimeType: 'application/octet-stream',
      );
      expect(safeSaveFileName(file, now: now), 'file_20260710_153000');
    });

    // Корень бага «file_<ts>»: отправитель (мост/бот) явно проставил
    // octet-stream, SDK не сниффил байты. Пересниффиваем сами по содержимому.
    test('octet-stream + png-байты → image_<ts>.png (снифф по содержимому)', () {
      final file = MatrixFile(
        bytes: pngBytes,
        name: '',
        mimeType: 'application/octet-stream',
      );
      expect(safeSaveFileName(file, now: now), 'image_20260710_153000.png');
    });

    test('пустой mime + jpeg-байты → image_<ts>.jpg', () {
      final file = MatrixFile(bytes: jpegBytes, name: '', mimeType: '');
      expect(safeSaveFileName(file, now: now), 'image_20260710_153000.jpg');
    });

    test('octet-stream + имя без ext + png-байты → добавляем .png', () {
      final file = MatrixFile(
        bytes: pngBytes,
        name: 'screenshot',
        mimeType: 'application/octet-stream',
      );
      expect(safeSaveFileName(file, now: now), 'screenshot.png');
    });

    test('валидный image/jpeg НЕ перетирается сниффом png-байтов', () {
      // Явный mime из события приоритетнее содержимого — снифф не вызывается.
      final file =
          MatrixFile(bytes: pngBytes, name: '', mimeType: 'image/jpeg');
      expect(safeSaveFileName(file, now: now), 'image_20260710_153000.jpg');
    });

    test('имя с хвостовой точкой не даёт двойного расширения', () {
      final file =
          MatrixFile(bytes: pngBytes, name: 'report.', mimeType: '');
      expect(safeSaveFileName(file, now: now), 'report.png');
    });

    // Реальный кейс 2026-07-17 (картинка от Нади): BMP из буфера Windows без
    // имени и без mimetype. package:mime не ловит BMP по содержимому — наш
    // _sniffMissingMagic обязан достроить `.bmp`, иначе снова `file_<ts>`.
    test('octet-stream + BMP-байты → image_<ts>.bmp (свой снифф)', () {
      final file = MatrixFile(
        bytes: bmpBytes,
        name: '',
        mimeType: 'application/octet-stream',
      );
      expect(safeSaveFileName(file, now: now), 'image_20260710_153000.bmp');
    });

    // Честный гэп: package:mime не знает SVG (текст без magic-числа) → снифф
    // вернёт null, имя останется без расширения. Фиксируем как известный предел.
    test('svg-байты (нет magic) + octet-stream → остаётся file_<ts>', () {
      final svgBytes = Uint8List.fromList('<svg xmlns'.codeUnits);
      final file = MatrixFile(
        bytes: svgBytes,
        name: '',
        mimeType: 'application/octet-stream',
      );
      expect(safeSaveFileName(file, now: now), 'file_20260710_153000');
    });
  });

  // ledger:RL-web-file-save-any-name
  group('safeSaveFileName: имя пригодно на любой платформе (заявка №51)', () {
    // На Web package:path работает в url-контексте: «:» читается как схема URL,
    // и p.url.extension('… 09:33 … .txt') == '' — file_picker бросал
    // «The file name should include a valid file extension». Тест на VM идёт в
    // posix-контексте, поэтому web-условие проверяем ЯВНО через p.url.
    const cases = {
      '2026-10-10 09:33 (MSK) 6250126185.txt':
          '2026-10-10 09_33 (MSK) 6250126185.txt',
      'a:b.txt': 'a_b.txt',
      'Отчёт: итог.pdf': 'Отчёт_ итог.pdf',
      'archive.tar.gz': 'archive.tar.gz',
      '../../x:y.txt': 'x_y.txt',
      'con|tent?.docx': 'con_tent_.docx',
      'a*b"c<d>e\\f.png': 'a_b_c_d_e_f.png',
      'tab\tname.txt': 'tab_name.txt',
    };
    for (final MapEntry(key: name, value: expected) in cases.entries) {
      test('«$name» → «$expected»', () {
        // AC:RL-web-file-save-any-name/1
        final file = MatrixFile(
          bytes: bytes,
          name: name,
          mimeType: 'application/octet-stream',
        );
        final result = safeSaveFileName(file, now: now);
        expect(result, expected);
        expect(result, isNot(matches(RegExp(r'[:/\\*?"<>|\x00-\x1f]'))));
        expect(p.url.extension(result), isNotEmpty);
        expect(p.url.extension(result), p.posix.extension(result));
        expect(p.windows.basename(result), result);
      });
    }

  });
}
