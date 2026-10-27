import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/xfile_mime.dart';

// WebM с Android уходил в событие как `audio/weba` (заявка №52): у XFile нет
// mimeType, SDK сниффит EBML-заголовок, а package:mime пишет его как аудио.
//
// ledger:RL-video-send-mime-normalize

const _ebml = [0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01];
const _mp4 = [
  0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, // ....ftyp
  0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00, // isom
];

String _mime(
  String name,
  String? declared,
  List<int> bytes, {
  bool transcoded = false,
}) => resolveVideoSendMime(
  declared: declared,
  name: name,
  bytes: bytes,
  transcoded: transcoded,
);

void main() {
  test('AC:RL-video-send-mime-normalize/1 — кейсы отправки видео', () {
    final cases = <(String, String?, List<int>, bool), String>{
      ('rec.webm', null, _ebml, false): 'video/webm',
      ('rec.webm', 'audio/weba', _ebml, false): 'video/webm',
      ('rec', null, _ebml, false): 'video/webm',
      ('clip.mp4', null, _mp4, false): 'video/mp4',
      ('clip.mp4', 'video/mp4', _mp4, false): 'video/mp4',
      ('IMG_1.mov', 'video/quicktime', _mp4, true): 'video/mp4',
      ('rec.webm', null, _mp4, true): 'video/mp4',
    };
    cases.forEach((input, expected) {
      final (name, declared, bytes, transcoded) = input;
      expect(
        _mime(name, declared, bytes, transcoded: transcoded),
        expected,
        reason: '$name declared=$declared transcoded=$transcoded',
      );
    });
    expect(_mime('movie.mkv', null, _ebml), startsWith('video/'));
  });

  test('AC:RL-video-send-mime-normalize/2 — getVideoInfo отдаёт в '
      'MatrixVideoFile результат resolveVideoSendMime', () {
    final source = File(
      'lib/utils/resize_video.dart',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    expect(source, contains('mimeType: resolveVideoSendMime('));
  });
}
