// Страж единого резолвера MIME для XFile (LABA-2620): набор медиа с Web из
// file_picker уходил не альбомом, а россыпью с подписью в каждом файле —
// отправка смотрела на `path` (blob:-URL), UI диалога на `name`.
//
// ledger:RL-xfile-mime-resolve

library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/pages/chat/send_file_dialog.dart';
import 'package:liza/utils/animated_gif.dart';
import 'package:liza/utils/heic_converter.dart';
import 'package:liza/utils/xfile_mime.dart';

/// Форма web-XFile от file_picker: `XFile.fromData(bytes, name:)` без
/// mimeType, `path` — blob:-URL. На io `XFile.fromData` берёт `name` из `path`,
/// поэтому web-форму на host даёт только подкласс с переопределёнными
/// геттерами (иначе тест моделировал бы не тот файл, что упал на проде).
class _WebPickedXFile extends XFile {
  final String _webName;
  _WebPickedXFile(this._webName, {String? mimeType})
    : _mime = mimeType,
      super.fromData(Uint8List.fromList([1, 2, 3]));
  final String? _mime;

  @override
  String get name => _webName;

  /// Как у настоящего blob:-URL — UUID без расширения: по path тип не узнать.
  @override
  String get path => 'blob:https://web.liza.ru/5b1d3c7e-9f0a-4c1e-8d2b-6a7f01c2d3e4';

  @override
  String? get mimeType => _mime;
}

/// Растр из буфера — как `_clipboardImageFile` в clipboard_paste.dart.
XFile _clipboard(String name) => XFile.fromData(
  Uint8List.fromList([137, 80, 78, 71]),
  mimeType: 'image/png',
  path: name,
  name: name,
);

void main() {
  group('resolveXFileMime', () {
    // AC:RL-xfile-mime-resolve/1
    test('AC-1: web-blob без mime → по имени', () {
      expect(resolveXFileMime(_WebPickedXFile('kofe.jpg')), 'image/jpeg');
      expect(resolveXFileMime(_WebPickedXFile('clip.mp4')), 'video/mp4');
    });

    test('AC-1: io-путь → как раньше по path', () {
      expect(resolveXFileMime(XFile('/tmp/a/clip.mp4')), 'video/mp4');
      expect(resolveXFileMime(XFile('/tmp/a/photo.PNG')), 'image/png');
    });

    test('AC-1: пустой mimeType не глушит фолбэк по имени', () {
      expect(
        resolveXFileMime(_WebPickedXFile('a.png', mimeType: '')),
        'image/png',
      );
    });

    test('AC-1: явный mimeType побеждает расширение', () {
      expect(
        resolveXFileMime(_WebPickedXFile('a.bin', mimeType: 'image/webp')),
        'image/webp',
      );
    });

    test('AC-1: ни mime, ни расширения → null', () {
      expect(resolveXFileMime(_WebPickedXFile('pasted_image_1')), isNull);
    });
  });

  group('isMediaAlbum', () {
    // AC:RL-xfile-mime-resolve/2 — ровно инцидентный набор 07.09.
    test('AC-2: jpg из file_picker (web, без mime) + вставки → альбом', () {
      expect(
        isMediaAlbum([
          _WebPickedXFile('kofe_osen_shliapa_117427_1920x1080.jpg'),
          _clipboard('clipboard_image.png'),
          _clipboard('clipboard_image_2.png'),
        ]),
        isTrue,
      );
    });

    test('AC-2: web-картинка + web-видео, io-файлы → альбом', () {
      expect(
        isMediaAlbum([_WebPickedXFile('a.jpg'), _WebPickedXFile('b.mp4')]),
        isTrue,
      );
      expect(
        isMediaAlbum([
          XFile('/t/a.jpg'),
          XFile('/t/b.png'),
          XFile('/t/c.mov'),
        ]),
        isTrue,
      );
    });

    // AC:RL-xfile-mime-resolve/3
    test('AC-3: pdf в наборе, один файл, файл без типа → не альбом', () {
      expect(
        isMediaAlbum([_WebPickedXFile('a.jpg'), _WebPickedXFile('b.pdf')]),
        isFalse,
      );
      expect(isMediaAlbum([_WebPickedXFile('a.jpg')]), isFalse);
      expect(
        isMediaAlbum([_WebPickedXFile('a.jpg'), _WebPickedXFile('noext')]),
        isFalse,
      );
    });
  });

  group('подпись набора — ровно одна', () {
    List<Map<String, dynamic>?> extras(List<XFile> files, String caption) {
      final galleryId = isMediaAlbum(files) ? 'gid' : null;
      return [
        for (var i = 0; i < files.length; i++)
          buildGalleryExtra(
            galleryId: galleryId,
            index: i,
            total: files.length,
            caption: caption,
          ),
      ];
    }

    // AC:RL-xfile-mime-resolve/4 — сквозной: тот же предикат, что у _send.
    test('AC-4: инцидентный набор → альбом, body только у i=0', () {
      final e = extras([
        _WebPickedXFile('kofe.jpg'),
        _clipboard('clipboard_image.png'),
        _clipboard('clipboard_image_2.png'),
      ], 'вуувув');
      expect(e.every((x) => x!.containsKey('com.liza.gallery')), isTrue);
      expect(e.where((x) => x!['body'] == 'вуувув').length, 1);
      expect(e.first!['body'], 'вуувув');
    });

    // AC:RL-xfile-mime-resolve/5 — pdf с подписью → «Вставить ещё» картинкой.
    test('AC-5: не-альбомный набор с подписью → подпись один раз', () {
      final e = extras([
        _WebPickedXFile('dogovor.pdf'),
        _clipboard('clipboard_image.png'),
        _clipboard('clipboard_image_2.png'),
      ], 'подпись');
      expect(e.any((x) => x?.containsKey('com.liza.gallery') ?? false), isFalse);
      expect(e.where((x) => x?['body'] == 'подпись').length, 1);
      expect(e.first!['body'], 'подпись');
      expect(e.skip(1).every((x) => x == null), isTrue);
    });
  });

  // AC:RL-xfile-mime-resolve/6 — второго предиката в обход резолвера нет.
  test('AC-6: в lib/ нет `mimeType ?? lookupMimeType(` вне резолвера', () {
    final offenders = <String>[];
    final pattern = RegExp(r'mimeType\s*\?\?\s*lookupMimeType\(');
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('xfile_mime.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty, reason: 'используй resolveXFileMime');
  });

  // AC:RL-xfile-mime-resolve/7 — соседи конвейера видят web-blob.
  test('AC-7: GIF и HEIC распознаются у web-blob без mime', () {
    expect(isGifXFile(_WebPickedXFile('cat.gif')), isTrue);
    expect(isHeicMimeType(resolveXFileMime(_WebPickedXFile('p.heic'))), isTrue);
    expect(
      resolveXFileMime(_WebPickedXFile('photo.jpg'))!.startsWith('image/'),
      isTrue,
    );
  });
}
