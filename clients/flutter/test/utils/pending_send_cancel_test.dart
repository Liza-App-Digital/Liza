// ledger:RL-pending-send-cancel
//
// LABA-2622: «Нет возможности отменить загрузку изображения, когда оно
// находится в очереди на отправку». Кроме крестика на пузыре фото (виджетный
// страж — `test/pages/chat/image_bubble_upload_cancel_test.dart`) тут —
// механика отмены: единый хелпер `cancelPendingSend`, его точки входа, пропуск
// файла сериёй и redact опоздавшей отмены.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/album_send_series.dart';
import 'package:liza/utils/upload_progress_tracker.dart';

import 'test_client.dart';

class _SpyRoom extends Room {
  _SpyRoom({required super.id, required super.client});

  final List<String> redacted = [];

  @override
  Future<String?> redactEvent(
    String eventId, {
    String? reason,
    String? txid,
  }) async {
    redacted.add(eventId);
    return '\$redaction';
  }
}

void main() {
  late Client client;
  late _SpyRoom room;
  final tracker = UploadProgressTracker.instance;
  final txids = [for (var i = 0; i < 5; i++) 'txn-cancel-$i'];

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    room = _SpyRoom(id: '!cancel:example.invalid', client: client);
    for (final t in txids) {
      tracker.register(t);
    }
  });

  tearDown(() async {
    for (final t in txids) {
      tracker.unregister(t);
    }
    await client.dispose(closeDatabase: true);
  });

  Event pending(String txid, {EventStatus status = EventStatus.sending}) =>
      Event(
        type: EventTypes.Message,
        eventId: txid,
        senderId: client.userID!,
        originServerTs: DateTime(2026, 9, 30),
        room: room,
        status: status,
        content: {'msgtype': MessageTypes.Image, 'body': '$txid.jpg'},
        unsigned: {'transaction_id': txid},
      );

  /// Серия из 5 фото, как её строит `SendFileDialog._send`: предикат отмены —
  /// РЕАЛЬНЫЙ трекер, а не подставленный набор индексов.
  Future<(SeriesResult, List<int>)> runSeries(
    Future<void> Function(int i) onUpload,
  ) async {
    final uploaded = <int>[];
    final result = await AlbumSendSeries<int>(
      count: txids.length,
      prepare: (i) async => i,
      upload: (i, _, _) async {
        uploaded.add(i);
        await onUpload(i);
      },
      sizeOf: (_) => 1,
      isCancelled: (i) => tracker.isCancelled(txids[i]),
      waitForReconnect: () async => true,
      delay: (_) async {},
    ).run();
    return (result, uploaded);
  }

  test('AC:RL-pending-send-cancel/3 — «Удалить» из меню во время отправки '
      'набора: серия НЕ досылает удалённое фото (red-proof: голый cancelSend '
      'флага не ставит и файл уходил)', () async {
    final (result, uploaded) = await runSeries((i) async {
      // Пользователь удаляет 3-е фото, пока заливается 1-е.
      if (i == 0) await cancelPendingSend(pending(txids[2]));
    });

    expect(result.outcomes[2], SeriesItemOutcome.cancelled);
    expect(uploaded, isNot(contains(2)), reason: 'заливки удалённого нет');
    expect(uploaded, [0, 1, 3, 4], reason: 'остальные ушли по порядку');
    expect(result.notSent, 0, reason: 'отмена — не «не отправлено»');
  });

  test('AC:RL-pending-send-cancel/3 — все точки удаления pending зовут '
      'единый хелпер, голого cancelSend в них не осталось', () {
    final sources = {
      'lib/pages/chat/chat.dart': 3,
      'lib/pages/chat/events/gallery.dart': 1,
      'lib/pages/chat/events/upload_overlays.dart': 1,
    };
    for (final MapEntry(key: path, value: calls) in sources.entries) {
      final code = File(path).readAsStringSync();
      expect(
        'cancelPendingSend('.allMatches(code).length,
        calls,
        reason: '$path: точек удаления pending',
      );
      expect(
        code.contains('.cancelSend()'),
        isFalse,
        reason: '$path: голый cancelSend не ставит флаг отмены',
      );
    }
  });

  test(
    'AC:RL-pending-send-cancel/4 — отмена после заливки (PUT /send уже '
    'ушёл): отправленное отзывается redact-ом ровно раз, итог cancelled',
    () async {
      const sentId = '\$sent-1:example.invalid';
      final (result, uploaded) = await runSeries((i) async {
        if (i != 1) return;
        // Крестик нажат, пока шёл PUT: sendFileEvent уже вернул настоящий id.
        tracker.requestCancel(txids[1]);
        if (revokeIfCancelledAfterSend(room, txids[1], sentId)) {
          throw const SendCancelledAfterUploadException();
        }
      });

      expect(room.redacted, [sentId]);
      expect(result.outcomes[1], SeriesItemOutcome.cancelled);
      expect(result.outcomes[0], SeriesItemOutcome.sent);
      expect(uploaded, [0, 1, 2, 3, 4]);
    },
  );

  test('AC:RL-pending-send-cancel/4 — `upload()` диалога отправки проверяет '
      'опоздавшую отмену сразу после sendFileEvent', () {
    final code = File(
      'lib/pages/chat/send_file_dialog.dart',
    ).readAsStringSync();
    final send = code.indexOf('eventId = await sendOnce();');
    final revoke = code.indexOf(
      'revokeIfCancelledAfterSend(room, txid, eventId)',
    );
    expect(send, greaterThan(0));
    expect(revoke, greaterThan(send), reason: 'проверка — после отправки');
    expect(
      code.indexOf('throw const SendCancelledAfterUploadException()', revoke),
      greaterThan(revoke),
    );
  });

  test('AC:RL-pending-send-cancel/4 — без отмены redact не зовётся', () {
    expect(
      revokeIfCancelledAfterSend(room, txids[0], '\$x:example.invalid'),
      isFalse,
    );
    expect(room.redacted, isEmpty);
  });

  test('AC:RL-pending-send-cancel/5 — после отмены байты файла и превью '
      'по txid освобождены', () async {
    final txid = txids[0];
    room.sendingFilePlaceholders[txid] = MatrixImageFile(
      bytes: Uint8List(1024),
      name: 'photo.jpg',
    );
    room.sendingFileThumbnails[txid] = MatrixImageFile(
      bytes: Uint8List(64),
      name: 'thumb.jpg',
    );

    await cancelPendingSend(pending(txid, status: EventStatus.error));

    expect(room.sendingFilePlaceholders.containsKey(txid), isFalse);
    expect(room.sendingFileThumbnails.containsKey(txid), isFalse);
    expect(tracker.isCancelled(txid), isTrue);
    expect(tracker.errorFor(txid), isNull, reason: 'не ошибка (LABA-2239)');
  });

  test('AC:RL-pending-send-cancel/5 — txid вне серии (текст, давно упавшее) '
      'флага не получает: снять его было бы некому', () async {
    const outside = 'txn-not-in-series';
    await cancelPendingSend(pending(outside, status: EventStatus.error));
    expect(tracker.isCancelled(outside), isFalse);
  });

  test('AC:RL-pending-send-cancel/5 — отменённому при eventId == null байты '
      'в sendingFilePlaceholders НЕ возвращаются', () {
    final code = File(
      'lib/pages/chat/send_file_dialog.dart',
    ).readAsStringSync();
    final nullBranch = code.indexOf('if (eventId == null) {');
    final guard = code.indexOf(
      'UploadProgressTracker.instance.isCancelled(txid)',
      nullBranch,
    );
    final restore = code.indexOf(
      'room.sendingFilePlaceholders[txid] = p.file;',
      nullBranch,
    );
    expect(nullBranch, greaterThan(0));
    expect(guard, greaterThan(nullBranch));
    expect(
      restore,
      greaterThan(guard),
      reason: 'проверка отмены — до возврата',
    );
  });
}
