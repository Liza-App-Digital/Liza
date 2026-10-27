// ledger:RL-windows-video-viewer-playback
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/matrix_sdk_extensions/matrix_file_extension.dart';

/// EBML-заголовок WebM/MKV: `mime` 2.0.0 по нему отдаёт `audio/weba`.
final _ebml = Uint8List.fromList([
  0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, //
  0x01, 0x42, 0xF2, 0x81, 0x04, 0x42, 0xF3, 0x81, 0x08, 0x42, 0x82, 0x84,
]);
final _jpeg = Uint8List.fromList([
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  ...List.filled(20, 0),
]);
final _mp4 = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, //
  ...List.filled(12, 0),
]);
final _ogg = Uint8List.fromList([
  0x4F,
  0x67,
  0x67,
  0x53,
  ...List.filled(20, 0),
]);

void main() {
  // AC:RL-windows-video-viewer-playback/6
  group('detectFileType сохраняет явный MIME', () {
    final cases = <(String, Uint8List, String, Type)>[
      ('запись.webm', _ebml, 'video/webm', MatrixVideoFile),
      ('clip.mkv', _ebml, 'video/x-matroska', MatrixVideoFile),
      ('clip.mp4', _mp4, 'video/mp4', MatrixVideoFile),
      ('photo.jpg', _jpeg, 'image/jpeg', MatrixImageFile),
      ('voice.ogg', _ogg, 'audio/ogg', MatrixAudioFile),
    ];
    for (final (name, bytes, mime, type) in cases) {
      test('$name → $mime', () {
        final file = MatrixFile(
          bytes: bytes,
          name: name,
          mimeType: mime,
        ).detectFileType;
        expect(file.mimeType, mime);
        expect(file.runtimeType, type);
      });
    }
  });

  // AC:RL-windows-video-viewer-playback/7
  test('без явного MIME — сниффинг как раньше', () {
    final file = MatrixFile(bytes: _jpeg, name: 'x').detectFileType;
    expect(file.mimeType, 'image/jpeg');
    expect(file, isA<MatrixImageFile>());
  });
}
