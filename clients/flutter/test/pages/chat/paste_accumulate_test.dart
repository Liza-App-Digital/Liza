// Страж накопления вставок в один альбом («➕ Вставить ещё») + целостности
// gallery-extra. Тестирует РЕАЛЬНЫЕ чистые функции `accumulate` и
// `buildGalleryExtra` (не реплики — снимает MOCK_ONLY, ср. инцидент 3704).
//
// ledger:RL-paste-accumulate-album

library;

import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/pages/chat/send_file_dialog.dart';
import 'package:liza/utils/clipboard_paste.dart';

XFile _named(String name) => XFile.fromData(
      Uint8List.fromList([137, 80, 78, 71, name.hashCode & 0xff]),
      mimeType: 'image/png',
      path: name,
      name: name,
    );

void main() {
  group('accumulate — накопление вставок в один альбом', () {
    // AC:RL-paste-accumulate-album/1 — два последовательных paste → [A,B], порядок.
    test('AC-1: [A] + [B] → [A,B], порядок сохранён', () async {
      final r = await accumulate([_named('a.png')], [_named('b.png')]);
      expect(r.map((f) => f.name).toList(), ['a.png', 'b.png']);
    });

    // AC:RL-paste-accumulate-album/2 — три накопления подряд → [A,B,C].
    test('AC-2: [A]→+[B]→+[C] → [A,B,C], порядок', () async {
      var r = await accumulate([_named('a.png')], [_named('b.png')]);
      r = await accumulate(r, [_named('c.png')]);
      expect(r.map((f) => f.name).toList(), ['a.png', 'b.png', 'c.png']);
    });

    // AC:RL-paste-accumulate-album/3 — накопление ПАЧКИ (не только по одному).
    test('AC-3: [A,B] + [C,D] → 4 в исходном порядке', () async {
      final r = await accumulate(
        [_named('a.png'), _named('b.png')],
        [_named('c.png'), _named('d.png')],
      );
      expect(r.map((f) => f.name).toList(), ['a.png', 'b.png', 'c.png', 'd.png']);
    });

    // Ре-нумерация коллизий: два скриншота приходят как clipboard_image.png —
    // без уникализации у получателя коллизия «Сохранить как»
    // (RL-multi-download-collision-safe).
    test('коллизия имён → уникализация _N, порядок сохранён', () async {
      final r = await accumulate(
        [_named('clipboard_image.png')],
        [_named('clipboard_image.png'), _named('clipboard_image.png')],
      );
      expect(r.length, 3);
      final names = r.map((f) => f.name).toList();
      expect(names.toSet().length, 3, reason: 'все имена уникальны');
      expect(names.first, 'clipboard_image.png');
      expect(names[1], 'clipboard_image_2.png');
      expect(names[2], 'clipboard_image_3.png');
    });

    test('уникальные имена не трогаются (реальные файлы не в RAM)', () async {
      final real = XFile('/tmp/photo.jpg');
      final r = await accumulate([_named('a.png')], [real]);
      expect(r[1].path, '/tmp/photo.jpg', reason: 'реальный путь сохранён как есть');
    });
  });

  group('buildGalleryExtra — целостность i/n/caption альбома', () {
    // AC:RL-paste-accumulate-album/4 — альбом: i индекс, n=факт, caption на i=0.
    test('AC-4: якорь (i=0) альбома → com.liza.gallery + caption + body', () {
      final extra = buildGalleryExtra(
        galleryId: 'gid1',
        index: 0,
        total: 3,
        caption: 'подпись',
      );
      expect(extra, isNotNull);
      final g = extra!['com.liza.gallery'] as Map;
      expect(g['id'], 'gid1');
      expect(g['i'], 0);
      expect(g['n'], 3);
      expect(g['caption'], 'подпись');
      expect(extra['body'], 'подпись');
    });

    test('AC-4: не-якорь (i=1) → без caption и без body', () {
      final extra = buildGalleryExtra(
        galleryId: 'gid1',
        index: 1,
        total: 3,
        caption: 'подпись',
      );
      final g = extra!['com.liza.gallery'] as Map;
      expect(g['i'], 1);
      expect(g['n'], 3);
      expect(g.containsKey('caption'), isFalse);
      expect(extra.containsKey('body'), isFalse);
    });

    test('одиночный файл (galleryId=null) + подпись → только body', () {
      final extra = buildGalleryExtra(
        galleryId: null,
        index: 0,
        total: 1,
        caption: 'подпись',
      );
      expect(extra!.containsKey('com.liza.gallery'), isFalse);
      expect(extra['body'], 'подпись');
    });

    // LABA-2620: набор, не ставший альбомом, повторял подпись в каждом файле.
    test('не-альбом (galleryId=null), i>0 → без body', () {
      final extra = buildGalleryExtra(
        galleryId: null,
        index: 1,
        total: 3,
        caption: 'подпись',
      );
      expect(extra, isNull);
    });

    test('одиночный файл без подписи → null (нет extraContent)', () {
      final extra = buildGalleryExtra(
        galleryId: null,
        index: 0,
        total: 1,
        caption: '',
      );
      expect(extra, isNull);
    });
  });
}
