import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/widgets/mxc_image.dart';

// ledger:RL-mxc-avatar-bad-bytes
// Роман 09.11: аватарки залипали человечком (person_2). Не-картинка с кодом 200
// кэшировалась в процессном LRU и не лечилась; «сбой» и «загрузка» выглядели
// одинаково. Страж: не-картинку мы отвергаем (AC-1), картинки принимаем (AC-2),
// AC-3 (буква вместо человечка при сбое) — manual: нужен живой Client.
void main() {
  Uint8List pad(List<int> head) {
    final b = Uint8List(16);
    for (var i = 0; i < head.length; i++) {
      b[i] = head[i];
    }
    return b;
  }

  group('AC:RL-mxc-avatar-bad-bytes/1 не-картинка отвергается (∀ кейсов)', () {
    final cases = <String, Uint8List>{
      'JSON-ошибка': Uint8List.fromList('{"errcode":"M_UNKNOWN"}'.codeUnits),
      'HTML прокси': Uint8List.fromList('<html><body>502</body></html>'.codeUnits),
      'пустое': Uint8List(0),
      'обрезок < 12 байт': Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
    };
    cases.forEach((name, bytes) {
      test(name, () => expect(MxcImage.looksLikeImageMagic(bytes), isFalse));
    });
  });

  group('AC:RL-mxc-avatar-bad-bytes/2 картинки принимаются (∀ форматов)', () {
    final cases = <String, Uint8List>{
      'JPEG': pad([0xFF, 0xD8, 0xFF, 0xE0]),
      'PNG': pad([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      'GIF': pad([0x47, 0x49, 0x46, 0x38]),
      'WebP': pad([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]),
    };
    cases.forEach((name, bytes) {
      test(name, () => expect(MxcImage.looksLikeImageMagic(bytes), isTrue));
    });
  });

  test('magicHex — 4 байта в hex, без media_id', () {
    expect(MxcImage.magicHex(pad([0xFF, 0xD8, 0xFF, 0xE0, 1, 2])), 'ffd8ffe0');
    expect(MxcImage.magicHex(Uint8List(0)), '');
  });
}
