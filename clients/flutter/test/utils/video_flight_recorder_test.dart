// ledger:RL-video-flight-recorder
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/video_flight_recorder.dart';

void main() {
  // AC:RL-video-flight-recorder/1 — кольцевые капы
  test('журналы ограничены капами', () {
    final r = VideoFlightRecorder();
    for (var i = 0; i < 100; i++) {
      r.recordUpstream(
        rangeStart: i * 1024 * 1024,
        status: 206,
        ttfbMs: 10,
        bytes: 1024,
        durationMs: 5,
        end: UpstreamEnd.complete,
      );
      r.event(FlightEvent.stalled);
    }
    for (var i = 0; i < 500; i++) {
      r.sample(cacheSec: 1, pausedForCache: false, speedKBs: 1, proxyKb: i);
    }
    final c = r.toContext();
    expect((c['upstream'] as List).length, lessThanOrEqualTo(32));
    expect((c['events'] as List).length, 20);
    expect(c['truncated'], isTrue);
  });

  // AC:RL-video-flight-recorder/2 — размер ≤ 8 КБ при любом наполнении
  test('контекст не превышает 8 КБ', () {
    final r = VideoFlightRecorder();
    for (var i = 0; i < 32; i++) {
      r.recordUpstream(
        rangeStart: 999999999999,
        status: 206,
        ttfbMs: 123456,
        bytes: 999999999,
        durationMs: 99999999,
        end: UpstreamEnd.progressTimeout,
      );
    }
    for (var i = 0; i < 120; i++) {
      r.sample(
        cacheSec: 99999,
        pausedForCache: true,
        speedKBs: 99999999,
        proxyKb: 99999999,
      );
    }
    expect(
      utf8.encode(jsonEncode(r.toContext())).length,
      lessThanOrEqualTo(VideoFlightRecorder.maxContextBytes),
    );
  });

  // AC:RL-video-flight-recorder/3 — приватность: только числа и enum
  test('в контексте нет строк кроме закрытых enum', () {
    final r = VideoFlightRecorder();
    r.recordUpstream(
      rangeStart: 0,
      status: 206,
      ttfbMs: 1,
      bytes: 1,
      durationMs: 1,
      end: UpstreamEnd.socket,
    );
    r.event(FlightEvent.failed);
    final json = jsonEncode(r.toContext());
    for (final bad in ['http', 'mxc', '@', 'Bearer', r'$', '!']) {
      expect(json.contains(bad), isFalse, reason: bad);
    }
  });

  // AC:RL-video-flight-recorder/4 — бакет Range
  test('Range округляется до 8 МБ', () {
    final r = VideoFlightRecorder();
    r.recordUpstream(
      rangeStart: 27 * 1024 * 1024 + 12345,
      status: 206,
      ttfbMs: null,
      bytes: 0,
      durationMs: 0,
      end: UpstreamEnd.cancelled,
    );
    final up = (r.toContext()['upstream'] as List).single as Map;
    expect(up['r'], 24);
    expect(up.containsKey('ttfb'), isFalse);
  });

  // AC:RL-video-flight-recorder/5 — две сессии не делят журнал
  test('рекордеры независимы', () {
    final a = VideoFlightRecorder()..event(FlightEvent.opened);
    final b = VideoFlightRecorder();
    expect((b.toContext()['events'] as List), isEmpty);
    expect((a.toContext()['events'] as List), hasLength(1));
  });
}
