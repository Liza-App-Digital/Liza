// Стражи E2EE-медиа-прокси:
//  1. B1 — резолв download-URI зашифрованного вложения (фикс мёртвого
//     `getAttachmentUri()`==null для E2EE).
//  2. R1 — корректность потоковой AES-CTR расшифровки с Range: логика
//     стриминга/выравнивания блоков/реконструкции counter (_serveDecrypted +
//     _adjustIv), впервые выводимая на боевой путь. Реальный AES живёт в
//     нативной либе vodozemac (в host-`flutter test` НЕ грузится), поэтому здесь
//     шифр инъектируется детерминированной заглушкой, зависящей от counter/
//     offset — она ловит любой сдвиг counter или ошибку выравнивания. Сам AES
//     (vodozemac) — device-flow AC-5/AC-6.
//
// Реестр: tests/registry/RL-e2ee-proxy-encrypted-download-uri.md
// Дизайн: docs/superpowers/specs/2026-08-19-macos-video-tmpdir-e2ee-proxy-design.md
//
// ledger:RL-e2ee-proxy-encrypted-download-uri
// guard.render: unit

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/e2ee_media_proxy.dart';

import 'test_client.dart';

/// Counter из IV (байты 8-15, big-endian) — та же раскладка, что пишет _adjustIv.
int _ivCounter(Uint8List iv) {
  var c = 0;
  for (var i = 8; i < 16; i++) {
    c = (c << 8) | iv[i];
  }
  return c;
}

/// Детерминированная замена AES-CTR: keystream зависит от АБСОЛЮТНОГО байт-
/// offset (= counter*16 + позиция), симметрична (XOR). Если прокси реконструирует
/// counter или выравнивание блоков неверно — расшифровка разъедется и байт-в-байт
/// сверка с plaintext покраснеет.
Uint8List _fakeCtr({
  required Uint8List input,
  required Uint8List key,
  required Uint8List iv,
}) {
  final base = _ivCounter(iv) * 16;
  final out = Uint8List(input.length);
  for (var j = 0; j < input.length; j++) {
    final p = base + j;
    // Mix полного offset: прежний линейный XOR повторялся через256 байт
    // и не ловил сброс CTR на resume2048 или смещение IV на16 блоков.
    var mixed = ((p ^ (p >> 16)) * 0x45d9f3b) & 0xffffffff;
    mixed = ((mixed ^ (mixed >> 16)) * 0x45d9f3b) & 0xffffffff;
    mixed ^= mixed >> 16;
    out[j] = input[j] ^ (mixed & 0xff);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveE2eeDownloadUri (B1: обход getAttachmentUri==null для E2EE)', () {
    late Client client;
    late Room room;

    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
      room = Room(id: '!r:example.invalid', client: client);
    });

    tearDown(() async {
      await E2eeMediaProxy.instance.stop();
      await client.dispose(closeDatabase: true);
    });

    Event encryptedVideoEvent({required bool withUrl}) => Event(
      type: EventTypes.Message,
      eventId: '\$vid1',
      senderId: '@alice:example.invalid',
      originServerTs: DateTime.now(),
      room: room,
      content: {
        'msgtype': 'm.video',
        'body': 'video.mp4',
        'file': {
          if (withUrl) 'url': 'mxc://example.invalid/AAAAmediaid',
          'key': {
            'k': 'BASE64KEY',
            'alg': 'A256CTR',
            'kty': 'oct',
            'ext': true,
            'key_ops': ['encrypt', 'decrypt'],
          },
          'iv': 'BASE64IV',
          'hashes': {'sha256': 'deadbeef'},
          'v': 'v2',
        },
        'info': {'size': 100, 'mimetype': 'video/mp4'},
      },
    );

    // AC:RL-e2ee-video-proxy-resume/6
    // AC:RL-video-stream-progress-and-lifecycle/11
    test(
      'две попытки одного event получают независимые непрозрачные leases',
      () async {
        final event = encryptedVideoEvent(withUrl: true);
        final file = event.content['file'] as Map;
        (file['key'] as Map)['k'] = base64Url.encode(Uint8List(32));
        file['iv'] = base64.encode(Uint8List(16));
        final proxy = E2eeMediaProxy.instance;
        final a = Uri.parse(await proxy.registerSession(event: event));
        final b = Uri.parse(await proxy.registerSession(event: event));
        expect(a, isNot(b));
        expect(a.path, isNot(contains('vid1')));
        await proxy.cancelSession(a.pathSegments.single);
        expect(proxy.snapshot(a.pathSegments.single), isNull);
        expect(proxy.snapshot(b.pathSegments.single), isNotNull);
      },
    );

    // AC:RL-e2ee-proxy-encrypted-download-uri/1
    test('AC-1: encrypted-событие → downloadUri резолвится из file.url '
        '(НЕ бросает getAttachmentUri-null)', () async {
      final event = encryptedVideoEvent(withUrl: true);
      expect(event.isAttachmentEncrypted, isTrue);
      expect(
        await event.getAttachmentUri(),
        isNull,
        reason: 'SDK getAttachmentUri по дизайну null для E2EE',
      );

      final uri = await E2eeMediaProxy.resolveE2eeDownloadUri(event);
      expect(uri.toString(), isNotEmpty);
      // v1 (`client/v1/media/download`) ИЛИ legacy v3 (`media/v3/download`).
      expect(uri.path, contains('download'));
      expect(uri.path, contains('example.invalid'));
      expect(uri.path, contains('AAAAmediaid'));
    });

    // AC:RL-e2ee-proxy-encrypted-download-uri/2
    test('AC-2: encrypted-событие БЕЗ file.url → контролируемый '
        'VideoProxyException (не немой старт)', () async {
      final event = encryptedVideoEvent(withUrl: false);
      expect(event.attachmentMxcUrl, isNull);
      expect(
        () => E2eeMediaProxy.resolveE2eeDownloadUri(event),
        throwsA(isA<VideoProxyException>()),
      );
    });

    // AC:RL-e2ee-proxy-encrypted-download-uri/2
    test(
      'AC-2b: file.url есть, но iv отсутствует (битый частичный sync) → '
      'registerSession бросает VideoProxyException (tryGet null-safe, не TypeError)',
      () async {
        final event = Event(
          type: EventTypes.Message,
          eventId: '\$vidNoIv',
          senderId: '@alice:example.invalid',
          originServerTs: DateTime.now(),
          room: room,
          content: {
            'msgtype': 'm.video',
            'body': 'video.mp4',
            'file': {
              'url': 'mxc://example.invalid/AAAAmediaid',
              'key': {'k': 'BASE64KEY', 'alg': 'A256CTR', 'kty': 'oct'},
              // iv намеренно отсутствует
              'hashes': {'sha256': 'deadbeef'},
              'v': 'v2',
            },
            'info': {'size': 100, 'mimetype': 'video/mp4'},
          },
        );
        expect(
          () => E2eeMediaProxy.instance.registerSession(event: event),
          throwsA(isA<VideoProxyException>()),
        );
      },
    );
  });

  group('_adjustIv: реконструкция counter (byte-carry)', () {
    Uint8List iv({int b14 = 0, int b15 = 0}) {
      final v = Uint8List(16);
      v[14] = b14;
      v[15] = b15;
      return v;
    }

    // AC:RL-e2ee-proxy-encrypted-download-uri/3
    test('AC-3e: blockOffset=0 → IV не меняется', () {
      final base = iv(b15: 0x42);
      expect(E2eeMediaProxy.adjustIvForTest(base, 0), equals(base));
    });

    // AC:RL-e2ee-proxy-encrypted-download-uri/3
    test('AC-3f: перенос через границу байта (0xFF + 1)', () {
      final r = E2eeMediaProxy.adjustIvForTest(iv(b14: 0x00, b15: 0xFF), 1);
      expect(r[15], 0x00);
      expect(r[14], 0x01);
    });

    // AC:RL-e2ee-proxy-encrypted-download-uri/3
    test('AC-3g: большой offset раскладывается big-endian', () {
      final r = E2eeMediaProxy.adjustIvForTest(iv(), 0x010000); // 65536
      expect(r[13], 0x01);
      expect(r[14], 0x00);
      expect(r[15], 0x00);
    });
  });

  group(
    'decryptCtrStream: расшифровка + Range на инъектированном шифре (R1)',
    () {
      late Uint8List plaintext;
      late Uint8List encrypted;

      late final savedCtr = E2eeMediaProxy.aesCtrImpl;

      setUpAll(() {
        // ignore: unnecessary_statements
        savedCtr; // зафиксировать оригинал до подмены
        E2eeMediaProxy.aesCtrImpl = _fakeCtr;
      });

      tearDownAll(() {
        E2eeMediaProxy.aesCtrImpl = savedCtr;
      });

      setUp(() {
        // 5000 = 312*16 + 8 → покрывает хвостовой неполный блок.
        plaintext = Uint8List.fromList(
          List.generate(5000, (i) => (i * 37 + 11) & 0xff),
        );
        // Шифруем тем же fake (counter=0) — decryptCtrStream расшифрует,
        // реконструируя counter из rangeStart.
        encrypted = _fakeCtr(
          input: plaintext,
          key: Uint8List(32),
          iv: Uint8List(16),
        );
      });

      /// Имитирует upstream: отдаёт encrypted[alignedStart..rangeEnd] кусками по 7
      /// байт (не кратно 16) — проверяет pending-буфер выравнивания. Возвращает
      /// расшифрованные байты для [rangeStart..rangeEnd].
      Future<Uint8List> decryptRange({
        required int rangeStart,
        required int rangeEnd,
        Uint8List? iv,
      }) async {
        final alignedStart = rangeStart - (rangeStart % 16);
        final slice = encrypted.sublist(alignedStart, rangeEnd + 1);
        Stream<List<int>> body() async* {
          for (var i = 0; i < slice.length; i += 7) {
            yield slice.sublist(i, min(i + 7, slice.length));
          }
        }

        final out = <int>[];
        await for (final c in E2eeMediaProxy.decryptCtrStream(
          encryptedBody: body(),
          keyBytes: Uint8List(32),
          baseIv: iv ?? Uint8List(16),
          rangeStart: rangeStart,
        )) {
          out.addAll(c);
        }
        return Uint8List.fromList(out);
      }

      // AC:RL-e2ee-proxy-encrypted-download-uri/3
      test('AC-3a: полный файл (rangeStart=0) == исходный plaintext', () async {
        expect(
          await decryptRange(rangeStart: 0, rangeEnd: 4999),
          equals(plaintext),
        );
      });

      // AC:RL-e2ee-proxy-encrypted-download-uri/3
      test('AC-3b: выровненный Range (start%16==0)', () async {
        expect(
          await decryptRange(rangeStart: 16, rangeEnd: 79),
          equals(plaintext.sublist(16, 80)),
        );
      });

      // AC:RL-e2ee-proxy-encrypted-download-uri/3
      test(
        'AC-3c: НЕвыровненный Range (start%16!=0) — критичный counter-кейс',
        () async {
          expect(
            await decryptRange(rangeStart: 17, rangeEnd: 100),
            equals(plaintext.sublist(17, 101)),
          );
        },
      );

      // AC:RL-e2ee-proxy-encrypted-download-uri/3
      test('AC-3d: хвостовой Range с неполным последним блоком', () async {
        expect(
          await decryptRange(rangeStart: 4990, rangeEnd: 4999),
          equals(plaintext.sublist(4990, 5000)),
        );
      });

      // AC:RL-e2ee-video-proxy-resume/7
      test(
        'red-proof oracle: IV+16 блоков (256 байт) НЕ совпадает с исходником',
        () async {
          final wrongIv = Uint8List(16)..[15] = 16;
          expect(
            await decryptRange(rangeStart: 0, rangeEnd: 4999, iv: wrongIv),
            isNot(equals(plaintext)),
          );
        },
      );

      // Red-proof: сдвиг counter (iv+1 блок) обязан дать ДРУГИЕ байты.
      test(
        'red-proof: сдвинутый IV (counter+1) ⇒ расшифровка НЕ совпадает',
        () async {
          final wrongIv = Uint8List(16)..[15] = 1; // counter=1
          final got = await decryptRange(
            rangeStart: 0,
            rangeEnd: 4999,
            iv: wrongIv,
          );
          expect(got, isNot(equals(plaintext)));
        },
      );
    },
  );
}
