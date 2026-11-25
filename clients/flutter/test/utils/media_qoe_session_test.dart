// ledger:RL-media-qoe-beacon
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/media_qoe_session.dart';

import 'media_qoe_test_support.dart';

void main() {
  late RecordingSink sink;
  late FakeStopwatch clock;

  setUp(() {
    sink = RecordingSink();
    clock = FakeStopwatch();
    MediaQoe.sink = sink;
    MediaQoe.net = 'wifi';
  });
  tearDown(() {
    MediaQoe.sink = null;
    MediaQoe.net = 'unknown';
  });

  MediaQoeViewSession session({String surface = 'viewer'}) =>
      MediaQoeViewSession(
        surface: surface,
        mime: 'video/mp4',
        sizeBytes: 5000000,
        e2ee: true,
        host: 'synapse.liza.laba.prodamus.tech',
        wallClockMs: () => 1700000000000,
        clock: clock,
      );

  // Каждый сценарий: шаги хоста → ожидаемый исход. Финал вызывается
  // повторно и вперемешку — эмит всё равно один.
  final scenarios = <String, (void Function(MediaQoeViewSession), String)>{
    'кадр → выход': (
      (s) {
        s.markFirstFrame(byDeadline: false);
        s.finishExit();
      },
      'success',
    ),
    'ошибка до кадра': ((s) => s.finishError(), 'vsf'),
    'ошибка после кадра': (
      (s) {
        s.markFirstFrame(byDeadline: false);
        s.finishError();
      },
      'vpf',
    ),
    'выход до кадра': ((s) => s.finishExit(), 'ebvs'),
    'свап → кадр → выход': (
      (s) {
        s.markSwapped();
        s.markFirstFrame(byDeadline: false);
        s.finishExit();
      },
      'swapped_ok',
    ),
    'свап → ошибка': (
      (s) {
        s.markSwapped();
        s.finishError();
      },
      'swapped_failed',
    ),
    'повтор до кадра': ((s) => s.finishRetry(), 'user_retry'),
    'повтор после кадра': (
      (s) {
        s.markFirstFrame(byDeadline: true);
        s.finishRetry();
      },
      'success',
    ),
  };

  group('AC:RL-media-qoe-beacon/1 — ровно один итог на попытку', () {
    for (final MapEntry(key: name, value: (steps, outcome))
        in scenarios.entries) {
      test('$name → $outcome', () {
        final s = session();
        expect(sink.opens, hasLength(1));
        expect(sink.opens.single['outcome'], 'abandoned_unknown');
        steps(s);
        s
          ..finishExit()
          ..finishError()
          ..finishRetry();
        expect(sink.finishes, hasLength(1));
        final event = sink.finishes.single;
        expect(event['outcome'], outcome);
        expect(event['attempt_id'], sink.opens.single['attempt_id']);
        expect(event['attempt_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(event['kind'], 'view');
        expect(s.finished, isTrue);
      });
    }

    test('измерения после итога не меняют отправленное', () {
      final s = session()..finishExit();
      s
        ..markFirstFrame(byDeadline: true)
        ..stallChanged(true)
        ..backgroundChanged(true);
      expect(sink.finishes.single['outcome'], 'ebvs');
      expect(sink.finishes.single.containsKey('ttff_ms'), isFalse);
    });
  });

  group('AC:RL-media-qoe-beacon/2 — измерения', () {
    test('ttff и frame_by_deadline — только первый кадр', () {
      final s = session();
      clock.ms = 1200;
      s.markFirstFrame(byDeadline: true);
      clock.ms = 5000;
      s.markFirstFrame(byDeadline: false);
      clock.ms = 9000;
      s.finishExit();
      final e = sink.finishes.single;
      expect(e['ttff_ms'], 1200);
      expect(e['frame_by_deadline'], isTrue);
      expect(e['watch_ms'], 9000);
      expect(e.containsKey('exit_before_frame_ms'), isFalse);
    });

    test('EBVS несёт сырое exit_before_frame_ms', () {
      final s = session();
      clock.ms = 8500;
      s.finishExit();
      expect(sink.finishes.single['exit_before_frame_ms'], 8500);
      expect(sink.finishes.single.containsKey('ttff_ms'), isFalse);
    });

    test('подвисания — только после первого кадра, открытое досчитано', () {
      final s = session();
      s.stallChanged(true); // ожидание старта — не подвисание
      clock.ms = 1000;
      s
        ..stallChanged(false)
        ..markFirstFrame(byDeadline: false);
      clock.ms = 2000;
      s.stallChanged(true);
      clock.ms = 2500;
      s.stallChanged(true); // повторный сэмпл того же подвисания
      clock.ms = 3000;
      s.stallChanged(false);
      clock.ms = 4000;
      s.stallChanged(true);
      clock.ms = 4700;
      s.finishExit();
      final e = sink.finishes.single;
      expect(e['stall_count'], 2);
      expect(e['stall_ms'], 1000 + 700);
    });

    test('bg_ms — сумма интервалов фона, незакрытый досчитан', () {
      final s = session();
      clock.ms = 100;
      s.backgroundChanged(true);
      clock.ms = 600;
      s.backgroundChanged(false);
      clock.ms = 1000;
      s.backgroundChanged(true);
      clock.ms = 1300;
      s.finishExit();
      expect(sink.finishes.single['bg_ms'], 500 + 300);
    });

    test('скорость — среднее ненулевых сэмплов; путь — закрытый enum', () {
      final s = session()
        ..addNetSample(0)
        ..addNetSample(1000)
        ..addNetSample(3000)
        ..addNetSample(null)
        ..setPath('proxy')
        ..setPath('/tmp/secret');
      s.finishExit();
      final e = sink.finishes.single;
      expect(e['net_bytes_per_s'], 2000);
      expect(e['path'], 'proxy');
      expect(e['net'], 'wifi');
      expect(e['surface'], 'viewer');
    });
  });

  group('AC:RL-media-qoe-beacon/4 — канарейки секретов (просмотр)', () {
    test('mime с параметрами и host с путём не протекают', () {
      MediaQoeViewSession(
        surface: 'story',
        mime: 'video/mp4; name="CANARY-file.mp4"',
        host: 'mxc://CANARY/abc',
        clock: clock,
      ).finishExit();
      MediaQoeViewSession(
        surface: 'viewer',
        mime: 'application/x-CANARY',
        host: 'evil.host/?access_token=CANARY',
        clock: clock,
      ).finishError();
      final dump = jsonEncode([...sink.opens, ...sink.finishes]);
      expect(dump, isNot(contains('CANARY')));
      expect(dump, isNot(contains('mxc://')));
      expect(sink.finishes.first['mime'], 'video/mp4');
      expect(sink.finishes.first.containsKey('host'), isFalse);
      expect(sink.finishes.last.containsKey('mime'), isFalse);
    });
  });

  group('AC:RL-media-qoe-beacon/7 — сбой маяка не трогает хоста', () {
    test('падающий приёмник: сессия живёт, вызовы не бросают', () {
      MediaQoe.sink = ThrowingSink();
      final s = session();
      expect(() {
        s
          ..markFirstFrame(byDeadline: false)
          ..stallChanged(true)
          ..finishExit();
      }, returnsNormally);
      expect(s.finished, isTrue);
    });

    test('без приёмника — молча ничего', () {
      MediaQoe.sink = null;
      expect(() => session().finishError(), returnsNormally);
    });
  });
}
