// Стражи классификатора причины сбоя получения вложения (`mediaFailureKind`) и
// его применения: честный `TranscriptionErrorKind` на стадии 1 транскрибации.
//
// Инцидент 2026-09-09 (GlitchTip issue #111/#112, устройство iPhone17,2,
// сборка 3747): у пользователя на 20 секунд пропала связь — прод-MMR за окно
// сбоя не получил НИ ОДНОГО запроса, а следующая попытка того же файла прошла
// успешно (скачивание 17:08:03 UTC → транскрибация 200 OK в 17:08:05). Но
// алёрт сказал `reason=transcription-decrypt`, а пользователь прочитал «Не
// удалось расшифровать голосовое сообщение»: оба catch-all вокруг ОДНОГО шага
// `downloadAndDecryptAttachmentHealed()` не различали сеть и расшифровку.
//
// ledger:RL-media-failure-kind

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/events/audio_autoplay_service.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/transcription_service.dart';
import 'test_client.dart';

void main() {
  group('mediaFailureKind — закрытый перечень, сеть ≠ расшифровка', () {
    // AC:RL-media-failure-kind/1
    test('AC-1: настоящий sha256-mismatch SDK → decrypt (и только он)', () {
      expect(mediaFailureKind(kDecryptFailure), 'decrypt');
      expect(isHealableDecryptFailure(kDecryptFailure), isTrue);
    });

    // AC:RL-media-failure-kind/2 — RED-PROOF инцидента: ∀ сетевым классам НЕ decrypt
    test('AC-2: ∀ сетевым сбоям → network/timeout, НИКОГДА не decrypt', () {
      final networkErrors = <Object>[
        const SocketException('Connection reset by peer'),
        const SocketException('Failed host lookup'),
        http.ClientException('Connection closed before full header'),
        const HandshakeException('TLS handshake failed'),
        // Голые TLS-классы: `HandshakeException`/`CertificateException` —
        // ПОДклассы `TlsException`, обратное неверно. Проверка по подклассам
        // роняла бы их в `other` → `decrypt` (та же ложь, что чиним).
        const TlsException('TLS error'),
        const CertificateException('Untrusted certificate'),
        const HttpException('Connection closed while receiving data'),
      ];
      for (final e in networkErrors) {
        expect(
          mediaFailureKind(e),
          'network',
          reason: 'сетевой сбой ${e.runtimeType} не должен зваться decrypt',
        );
      }
      expect(mediaFailureKind(TimeoutException('slow')), 'timeout');
    });

    // AC:RL-media-failure-kind/3
    test('AC-3: ошибка доставки сервера (HTTP≥400 / error-page) → http', () {
      expect(
        mediaFailureKind(const MediaDownloadException(statusCode: 404)),
        'http',
      );
      expect(
        mediaFailureKind(
          const MediaDownloadException(
            statusCode: 200,
            contentType: 'application/json',
          ),
        ),
        'http',
      );
    });

    // AC:RL-media-failure-kind/4
    test('AC-4: прочие голые строки SDK → sdk, остальное → other '
        '(не маскируются под сеть)', () {
      expect(mediaFailureKind('Unable to download file from local store.'), 'sdk');
      expect(mediaFailureKind("Missing 'decrypt' in 'key_ops'."), 'sdk');
      expect(mediaFailureKind(StateError('boom')), 'other');
      expect(mediaFailureKind(Exception('boom')), 'other');
    });

    // AC:RL-media-failure-kind/5
    test('AC-5: kind не несёт текста ошибки (PII/локатор контента) ∀ входам', () {
      final errors = <Object>[
        const SocketException('mxc://synapse.liza/AbCdEf host 1.2.3.4'),
        http.ClientException('/var/tmp/mxc_AbCdEf_recording.m4a'),
        Exception('Bearer syt_secret_token'),
        kDecryptFailure,
      ];
      const forbidden = ['mxc://', '/var/', '/tmp/', 'bearer', 'syt_', '@'];
      for (final e in errors) {
        final kind = mediaFailureKind(e);
        for (final bad in forbidden) {
          expect(kind.toLowerCase(), isNot(contains(bad)),
              reason: 'kind="$kind" не должен нести "$bad"');
        }
      }
    });
  });

  // Инцидент 2026-09-23 (GlitchTip #2057, iPhone15,2, сборка 3764): алёрт
  // `[audio-fail] reason=download-fail kind=other …` не нёс НИ ОДНОЙ зацепки —
  // что именно упало, знал только лог на устройстве.
  group('err при kind=other — тип ошибки доезжает до дежурного', () {
    // AC:RL-media-failure-kind/9 AC:RL-mediadiag-no-secret/err
    test('AC-9: mediaFailureErrorType = имя типа, БЕЗ текста/пути/токена', () {
      final cases = <Object, String>{
        const FileSystemException(
          'Cannot open file',
          '/var/mobile/tmp/liza_media_cache/mxc_AbCdEf',
        ): 'FileSystemException',
        const PathNotFoundException(
          '/tmp/liza_media_cache/mxc_AbCdEf',
          OSError('No such file'),
        ): 'PathNotFoundException',
        StateError('Bearer syt_secret_token @u:liza'): 'StateError',
        const FormatException('mxc://synapse.liza/AbCdEf'): 'FormatException',
        <String, dynamic>{'errcode': 'M_UNKNOWN'}: '_Map',
      };
      const forbidden = ['mxc', '/', 'bearer', 'syt_', '@', '<', ' '];
      cases.forEach((error, expected) {
        final type = mediaFailureErrorType(error);
        expect(type, expected);
        expect(type.length, lessThanOrEqualTo(40));
        for (final bad in forbidden) {
          expect(
            type.toLowerCase(),
            isNot(contains(bad)),
            reason: 'err="$type" не должен нести "$bad"',
          );
        }
      });
    });

    // AC:RL-media-failure-kind/10
    test(
      'AC-10: реальный audioIssueContext — err идёт сразу за kind только при '
      'other и переживает бюджет title на ∀ хостах парка',
      () async {
        final client = await prepareTestClient();
        final room = Room(
          id: '!r:synapse.liza.laba.prodamus.tech',
          client: client,
        );
        Event voice({bool encrypted = false, String mime = 'audio/mp4'}) =>
            Event(
              content: {
                'msgtype': 'm.audio',
                'body': 'voice.m4a',
                if (!encrypted) 'url': 'mxc://synapse.liza/AbCdEf',
                if (encrypted)
                  'file': {'url': 'mxc://synapse.liza/AbCdEf', 'v': 'v2'},
                'info': {'mimetype': mime, 'size': 200000},
              },
              type: EventTypes.Message,
              eventId: r'$e',
              senderId: '@a:synapse.liza.laba.prodamus.tech',
              originServerTs: DateTime(2026, 9, 23),
              room: room,
            );
        const error = PathNotFoundException('/tmp/x', OSError('gone'));

        final ctx = audioIssueContext(voice(), error: error);
        expect(ctx.keys.take(2), ['kind', 'err']);
        expect(ctx['kind'], 'other');
        expect(ctx['err'], 'PathNotFoundException');
        for (final e in <Object>[
          const SocketException('reset'),
          TimeoutException('slow'),
          const MediaDownloadException(statusCode: 404),
          kDecryptFailure,
          'Unable to download file from local store.',
        ]) {
          expect(
            audioIssueContext(voice(), error: e).containsKey('err'),
            isFalse,
            reason: 'err только для other, не для ${mediaFailureKind(e)}',
          );
        }
        expect(audioIssueContext(voice()).containsKey('err'), isFalse);

        for (final host in [
          'synapse.liza.laba.prodamus.tech',
          'liza.cyber-agro.ru',
          'victoryeng.liza.ru',
        ]) {
          for (final encrypted in [false, true]) {
            final title = Monitoring.buildAlertTitle(
              prefix: Monitoring.audioFailurePrefix,
              reason: 'download-fail',
              host: host,
              context: audioIssueContext(
                voice(encrypted: encrypted, mime: 'application/octet-stream'),
                error: StateError('x'),
              ),
            );
            expect(
              title.length,
              lessThanOrEqualTo(Monitoring.maxAlertTitleLength),
            );
            expect(title, contains('kind=other err=StateError'));
          }
        }
      },
    );
  });

  // GlitchTip #2081 (2026-09-27, Windows 3764): `[audio-fail]
  // reason=playback-error` без текста — на media_kit `errorStream` несёт любую
  // строку уровня `error` из лога mpv, включая нефатальные, и отличить «не
  // открылся файл» от «битый кадр» было нечем.
  group('err у сбоя плеера — класс текста PlayerException', () {
    // AC:RL-media-failure-kind/11 AC:RL-mediadiag-no-secret/player-err
    test('AC-11: audioPlayerErrorClass — закрытый перечень ∀ строкам mpv, '
        'без текста/пути/URL', () {
      final cases = <String?, String>{
        r'Failed to open C:\Users\Иван\AppData\Local\Temp\voice.m4a.': 'open',
        'Failed to open https://user.liza.ru/_matrix/client/v1/media/download/x.':
            'open',
        'Failed to recognize file format.': 'format',
        'Error decoding audio.': 'decode',
        'Error while decoding frame!': 'decode',
        'Could not open codec.': 'codec',
        'tcp: Connection to tcp://user.liza.ru:443 failed: Error number -138':
            'network',
        'Source error': 'other',
        '': 'none',
        null: 'none',
      };
      const allowed = {
        'open',
        'format',
        'decode',
        'codec',
        'network',
        'other',
        'none',
      };
      cases.forEach((message, expected) {
        final cls = audioPlayerErrorClass(message);
        expect(cls, expected, reason: 'message="$message"');
        expect(allowed, contains(cls));
      });
    });

    // AC:RL-media-failure-kind/12
    test(
      'AC-12: реальный audioIssueContext — err плеера идёт ПЕРВЫМ и переживает '
      'бюджет title ∀ хостам × e2ee; без playerError поля нет',
      () async {
        final client = await prepareTestClient();
        final room = Room(
          id: '!r:synapse.liza.laba.prodamus.tech',
          client: client,
        );
        Event voice({bool encrypted = false}) => Event(
          content: {
            'msgtype': 'm.audio',
            'body': 'voice.m4a',
            if (!encrypted) 'url': 'mxc://user.liza.ru/AbCdEf',
            if (encrypted)
              'file': {'url': 'mxc://user.liza.ru/AbCdEf', 'v': 'v2'},
            'info': {'mimetype': 'application/octet-stream', 'size': 200000},
          },
          type: EventTypes.Message,
          eventId: r'$e',
          senderId: '@a:user.liza.ru',
          originServerTs: DateTime(2026, 9, 27),
          room: room,
        );

        final ctx = audioIssueContext(
          voice(),
          playerError: 'Error decoding audio.',
        );
        expect(ctx.keys.first, 'err');
        expect(ctx['err'], 'decode');
        expect(audioIssueContext(voice()).containsKey('err'), isFalse);

        for (final reason in [
          'playback-error',
          'source-error',
          'autoplay-next-fail',
        ]) {
          for (final host in [
            'synapse.liza.laba.prodamus.tech',
            'user.liza.ru',
            'liza.cyber-agro.ru',
          ]) {
            for (final encrypted in [false, true]) {
              final title = Monitoring.buildAlertTitle(
                prefix: Monitoring.audioFailurePrefix,
                reason: reason,
                host: host,
                context: audioIssueContext(
                  voice(encrypted: encrypted),
                  playerError: 'Could not open codec.',
                ),
              );
              expect(title.length, lessThanOrEqualTo(99), reason: title);
              expect(title, contains('reason=$reason'));
              expect(title, contains('err=codec'), reason: title);
            }
          }
        }
      },
    );
  });

  group('TranscriptionService.stageOneKindFor — честный вид ошибки', () {
    // AC:RL-media-failure-kind/6 — то самое, что соврало пользователю
    test('AC-6: сетевой сбой на стадии 1 → network (НЕ decrypt): пользователь '
        'больше не читает «Не удалось расшифровать» при живом файле', () {
      expect(
        TranscriptionService.stageOneKindFor(
          const SocketException('Connection reset by peer'),
        ),
        TranscriptionErrorKind.network,
      );
      expect(
        TranscriptionService.stageOneKindFor(
          http.ClientException('Connection closed'),
        ),
        TranscriptionErrorKind.network,
      );
      expect(
        TranscriptionService.stageOneKindFor(
          const MediaDownloadException(statusCode: 502),
        ),
        TranscriptionErrorKind.network,
      );
      expect(
        TranscriptionService.stageOneKindFor(TimeoutException('slow')),
        TranscriptionErrorKind.timeout,
      );
    });

    // AC:RL-media-failure-kind/7
    test('AC-7: настоящий сбой расшифровки остаётся decrypt; неопознанное — '
        'консервативно decrypt (фолбэк прежнего поведения, не ложь про сеть)', () {
      expect(
        TranscriptionService.stageOneKindFor(kDecryptFailure),
        TranscriptionErrorKind.decrypt,
      );
      expect(
        TranscriptionService.stageOneKindFor(StateError('boom')),
        TranscriptionErrorKind.decrypt,
      );
    });
  });
}
