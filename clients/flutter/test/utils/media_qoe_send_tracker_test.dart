// ledger:RL-media-qoe-beacon
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/media_qoe_session.dart';
import 'package:liza/utils/upload_progress_tracker.dart';

import 'media_qoe_test_support.dart';

void main() {
  late RecordingSink sink;
  final tracker = UploadProgressTracker.instance;
  var n = 0;
  String txid() => 'm${DateTime.now().microsecondsSinceEpoch}.${n++}';

  setUp(() {
    sink = RecordingSink();
    MediaQoe.sink = sink;
  });
  tearDown(() => MediaQoe.sink = null);

  void startVideo(String id) => tracker.register(
    id,
    mime: 'video/mp4',
    sizeBytes: 4000000,
    e2ee: true,
    album: false,
  );

  group('AC:RL-media-qoe-beacon/3 — итог отправки по хукам трекера', () {
    test('sent: фазы → один итог с длительностями', () {
      final id = txid();
      startVideo(id);
      tracker
        ..reportPhase(id, UploadPhase.compressing)
        ..reportPhase(id, UploadPhase.uploading)
        ..reportSent(id)
        ..unregister(id);
      expect(sink.opens, hasLength(1));
      expect(sink.finishes, hasLength(1));
      expect(sink.drops, isEmpty);
      final e = sink.finishes.single;
      expect(e['kind'], 'send');
      expect(e['outcome'], 'sent');
      expect(e['attempt_id'], sink.opens.single['attempt_id']);
      expect(e['size_bytes'], 4000000);
      expect(e['e2ee'], isTrue);
      for (final f in ['prepare_ms', 'compress_ms', 'upload_ms']) {
        expect(e[f], isA<int>(), reason: f);
      }
    });

    test('terminal: failed_terminal с закрытым error_kind', () {
      final id = txid();
      startVideo(id);
      tracker
        ..reportFailed(id, 'terminal')
        ..unregister(id);
      expect(sink.finishes.single['outcome'], 'failed_terminal');
      expect(sink.finishes.single['error_kind'], 'terminal');
    });

    test('отмена крестиком → canceled', () {
      final id = txid();
      startVideo(id);
      tracker
        ..requestCancel(id)
        ..unregister(id);
      expect(sink.finishes.single['outcome'], 'canceled');
    });

    test('повтор того же txid — новая попытка с новым attempt_id', () {
      final id = txid();
      startVideo(id);
      tracker
        ..reportFailed(id, 'transient')
        ..unregister(id);
      startVideo(id);
      startVideo(id); // повторный register на открытой попытке — та же
      tracker
        ..reportSent(id)
        ..unregister(id);
      expect(sink.opens, hasLength(2));
      expect(sink.finishes.map((e) => e['outcome']), [
        'failed_terminal',
        'sent',
      ]);
      expect(
        sink.finishes.first['attempt_id'],
        isNot(sink.finishes.last['attempt_id']),
      );
    });

    test('unregister без итога → 0 итогов, попытка снята', () {
      final id = txid();
      startVideo(id);
      tracker.unregister(id);
      expect(sink.finishes, isEmpty);
      expect(sink.drops, [sink.opens.single['attempt_id']]);
    });

    test('голосовое и register без mime маяк не открывают', () {
      final a = txid();
      final b = txid();
      tracker
        ..register(a, mime: 'audio/ogg')
        ..register(b)
        ..reportSent(a)
        ..reportSent(b)
        ..unregister(a)
        ..unregister(b);
      expect(sink.opens, isEmpty);
      expect(sink.finishes, isEmpty);
    });
  });

  group('AC:RL-media-qoe-beacon/4 — канарейки секретов (отправка)', () {
    test('error_kind и mime вне закрытого формата отбрасываются', () {
      final id = txid();
      tracker
        ..register(id, mime: 'image/jpeg; name=CANARY.jpg', sizeBytes: 10)
        ..reportFailed(id, 'mxc://CANARY/x')
        ..unregister(id);
      final dump = jsonEncode([...sink.opens, ...sink.finishes]);
      expect(dump, isNot(contains('CANARY')));
      expect(sink.finishes.single.containsKey('error_kind'), isFalse);
      expect(sink.finishes.single['mime'], 'image/jpeg');
    });
  });

  group('AC:RL-media-qoe-beacon/7 — сбой маяка не трогает трекер', () {
    test('падающий приёмник: прогресс/фаза/отмена работают как раньше', () {
      MediaQoe.sink = ThrowingSink();
      final id = txid();
      final notifier = tracker.register(id, mime: 'video/mp4');
      expect(tracker.byId(id), same(notifier));
      tracker.reportPhase(id, UploadPhase.uploading);
      expect(tracker.phaseFor(id)!.value, UploadPhase.uploading);
      tracker.requestCancel(id);
      expect(tracker.isCancelled(id), isTrue);
      tracker.unregister(id);
      expect(tracker.byId(id), isNull);
      expect(tracker.isCancelled(id), isFalse);
    });
  });
}
