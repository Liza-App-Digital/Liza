// GlitchTip #2080 (2026-09-26, iPhone 3770): видео-альбом из трёх файлов,
// третий (211 МБ) ждал своей очереди на заливку с 08:25 до 12:17. Liza рисует
// пузыри альбома ДО передачи файлов в SDK (`preEmitBubbles`), поэтому у такого
// пузыря нет ни `url`, ни байтов в `sendingFilePlaceholders`. Тап в 11:03 уводил
// просмотрщик в скачивание → свап → `[video-fail] reason=swap-failed` («This
// event hasn't any attachment or thumbnail.») и экран «Не удалось воспроизвести».
// На сервере медиа-событий без `url` нет ни одного (проверено по БД прод-Synapse:
// 0 из 10 012) — такое событие рождает только сам клиент.
//
// Почему для просмотрщика source-scan, а не widget-тест: плеер — libmpv, на
// host его не поднять (тот же приём, что у AC:RL-video-viewer-save-and-overlay/6).
//
// ledger:RL-video-playback-monitoring-signal

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/file_description.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import '../../utils/test_client.dart';

Event _video(
  Room room, {
  required EventStatus status,
  String? url,
  String eventId = 'Liza ios-5-1790411103801',
}) => Event.fromMatrixEvent(
  MatrixEvent(
    content: {
      'msgtype': MessageTypes.Video,
      'body': 'IMG_0001.MOV',
      if (url != null) 'url': url,
      'info': {'mimetype': 'video/mp4', 'size': 211000000},
    },
    type: EventTypes.Message,
    eventId: eventId,
    senderId: '@alice:example.invalid',
    originServerTs: DateTime.now(),
    unsigned: {'transaction_id': eventId},
  ),
  room,
  status: status,
);

void main() {
  late Client client;
  late Room room;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!album:example.invalid', client: client);
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  // AC:RL-video-playback-monitoring-signal/12
  test(
    'AC-12: isPendingMediaWithoutBytes — только отправляемая копия без url и '
    'без байтов у SDK',
    () {
      // Пузырь альбома, ещё не переданный в SDK (случай #2080).
      for (final status in [EventStatus.sending, EventStatus.error]) {
        expect(
          _video(room, status: status).isPendingMediaWithoutBytes,
          isTrue,
          reason: 'status=$status без url и байтов',
        );
      }

      // Файл уже у SDK — играем локальные байты, как раньше.
      room.sendingFilePlaceholders['Liza ios-5-1790411103801'] = MatrixFile(
        bytes: Uint8List(4),
        name: 'IMG_0001.MOV',
      );
      expect(
        _video(room, status: EventStatus.sending).isPendingMediaWithoutBytes,
        isFalse,
      );
      room.sendingFilePlaceholders.clear();

      // Залито (есть url) или уже на сервере — обычный путь воспроизведения.
      expect(
        _video(
          room,
          status: EventStatus.sending,
          url: 'mxc://example.invalid/abc',
        ).isPendingMediaWithoutBytes,
        isFalse,
      );
      for (final status in [EventStatus.sent, EventStatus.synced]) {
        expect(
          _video(
            room,
            status: status,
            eventId: r'$ev',
          ).isPendingMediaWithoutBytes,
          isFalse,
          reason: 'status=$status',
        );
      }
    },
  );

  // AC:RL-video-playback-monitoring-signal/14 — контрпример adversarial-verifier:
  // заливка упала (`error`), SDK оставил байты в `sendingFilePlaceholders`, но
  // сам отдаёт их только при `isSending` и на `error` бросает ту же ошибку #2080.
  test('AC-14: error-копия с байтами у SDK — файл отдаётся локально, а не '
      '«hasn\'t any attachment»', () async {
    final bytes = MatrixFile(bytes: Uint8List(4), name: 'IMG_0001.MOV');
    room.sendingFilePlaceholders['Liza ios-5-1790411103801'] = bytes;
    final event = _video(room, status: EventStatus.error);
    expect(event.isPendingMediaWithoutBytes, isFalse);
    expect(
      identical(await event.downloadAndDecryptAttachmentHealed(), bytes),
      isTrue,
    );
    room.sendingFilePlaceholders.clear();
  });

  // AC:RL-video-playback-monitoring-signal/13
  test(
    'AC-13: просмотрщик выходит ДО стрима/скачивания и без алёрта, показывая '
    '«ещё отправляется»',
    () {
      final source = File(
        'lib/pages/image_viewer/video_player.dart',
      ).readAsStringSync();
      final startAt = source.indexOf('Future<void> _start() async {');
      expect(startAt, isNot(-1), reason: 'не найден _start — тест устарел');
      final body = source.substring(startAt);
      final guard = body.indexOf('event.isPendingMediaWithoutBytes');
      final firstTry = body.indexOf('try {');
      expect(guard, isNot(-1), reason: '_start обязан проверять пустую копию');
      expect(
        guard,
        lessThan(firstTry),
        reason: 'проверка обязана стоять ДО стрима/скачивания/свапа',
      );
      final branch = body.substring(guard, firstTry);
      expect(branch, contains('_awaitingUpload = true'));
      expect(branch, contains('return;'));
      expect(
        branch,
        isNot(contains('Monitoring')),
        reason: 'неотправленное видео — не сбой плеера, алёрта быть не должно',
      );
      expect(source.contains("Key('video-awaiting-upload-overlay')"), isTrue);
    },
  );

  // AC:RL-video-playback-monitoring-signal/15
  test('AC-15: провалившаяся отправка — «не удалось отправить», а не вечное '
      '«ещё отправляется»', () {
    final source = File(
      'lib/pages/image_viewer/video_player.dart',
    ).readAsStringSync();
    final startAt = source.indexOf('Future<void> _start() async {');
    final body = source.substring(startAt);
    final branch = body.substring(
      body.indexOf('event.isPendingMediaWithoutBytes'),
      body.indexOf('try {'),
    );
    expect(branch, contains('_uploadFailed = event.status.isError'));
    final overlayAt = source.indexOf('Widget _buildAwaitingUploadOverlay(');
    final overlay = source.substring(
      overlayAt,
      source.indexOf('Widget _buildErrorOverlay(', overlayAt),
    );
    expect(overlay, contains('_uploadFailed'));
    expect(overlay, contains('videoSendFailed'));
    expect(overlay, contains('videoStillUploading'));
  });
}
