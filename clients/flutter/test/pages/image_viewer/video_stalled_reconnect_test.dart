// ledger:RL-video-stalled-reconnect-terminal
// Реальный mpv trace: decoder stream-pos замер, upstream/cache растут.
// Дедлайн измеряет полезный прогресс, а не позицию чтения декодера.
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/pages/image_viewer/video_player.dart';

void main() {
  bool observe(
    StalledReconnectDetector d,
    int seconds, {
    int? bytes,
    double? cache,
    double? speed,
    int positionMs = 0,
    bool active = true,
    int budget = 120,
  }) => d.observe(
    now: Duration(seconds: seconds),
    budget: Duration(seconds: budget),
    active: active,
    receivedBytes: bytes,
    cacheDuration: cache,
    cacheSpeed: speed,
    position: Duration(milliseconds: positionMs),
  );

  test('реальный mpv trace t4..20: frozen decoder не terminal', () {
    final d = StalledReconnectDetector();
    for (var t = 4; t <= 20; t += 2) {
      // Реальная запись: stream-pos=128235 всё окно, cache 0.20→4.72,
      // upstream 163840→811008. stream-pos намеренно отсутствует в API.
      expect(
        observe(
          d,
          t,
          bytes: 163840 + (t - 4) * 40448,
          cache: 0.20 + (t - 4) * 0.2825,
          speed: 40960,
        ),
        isFalse,
      );
    }
  });

  test('AC-1: чанки раз в 2 и 59 секунд за 240с не дают terminal', () {
    // AC:RL-video-stalled-reconnect-terminal/1
    for (final interval in [2, 59]) {
      final d = StalledReconnectDetector();
      for (var t = 0; t <= 240; t++) {
        expect(
          observe(d, t, bytes: (t ~/ interval) * 1024),
          isFalse,
          reason: 'interval=$interval t=$t',
        );
      }
    }
  });

  test('AC-2: рывковый проверенный upstream сбрасывает idle', () {
    // AC:RL-video-stalled-reconnect-terminal/2
    final d = StalledReconnectDetector();
    for (var t = 0; t <= 480; t += 2) {
      expect(observe(d, t, bytes: (t ~/ 100) * 15000000), isFalse);
    }
  });

  test(
    'AC-3: скорость, рост кэша, playback по отдельности запрещают terminal',
    () {
      // AC:RL-video-stalled-reconnect-terminal/3
      for (var mode = 0; mode < 3; mode++) {
        final d = StalledReconnectDetector();
        for (var t = 0; t <= 240; t += 2) {
          expect(
            observe(
              d,
              t,
              budget: 60,
              speed: mode == 0 ? 4096 : null,
              cache: mode == 1 ? t / 5 : null,
              positionMs: mode == 2 ? t * 1000 : 0,
            ),
            isFalse,
          );
        }
      }
    },
  );

  test('AC-4: без прогресса ровно один terminal на 120с, не раньше', () {
    // AC:RL-video-stalled-reconnect-terminal/4
    final d = StalledReconnectDetector();
    final terminals = <int>[];
    for (var t = 0; t < 240; t += 2) {
      if (observe(d, t, bytes: 10485796)) terminals.add(t);
    }
    expect(terminals, [120]);
  });

  test('AC-6: unavailable не zero; при живом playback не terminal', () {
    // AC:RL-video-stalled-reconnect-terminal/6
    final d = StalledReconnectDetector();
    for (var t = 0; t <= 240; t += 2) {
      expect(observe(d, t, budget: 60, positionMs: t * 1000), isFalse);
    }
    // Ни одного доступного свойства и playback тоже стоит: bounded recovery.
    final unavailable = StalledReconnectDetector();
    expect(observe(unavailable, 0, budget: 60), isFalse);
    expect(observe(unavailable, 59, budget: 60), isFalse);
    expect(observe(unavailable, 60, budget: 60), isTrue);
  });

  test('AC-7: reset/retry снимает latch, пауза даёт полный новый budget', () {
    // AC:RL-video-stalled-reconnect-terminal/7
    final d = StalledReconnectDetector();
    expect(observe(d, 0), isFalse);
    expect(observe(d, 120), isTrue);
    d.reset();
    expect(observe(d, 120), isFalse);
    expect(observe(d, 240), isTrue);
    expect(observe(d, 420, active: false), isFalse);
    expect(observe(d, 600), isFalse);
    expect(observe(d, 719), isFalse);
    expect(observe(d, 720), isTrue);
  });

  test('seek назад не является download-counter и не прячет будущий idle', () {
    final d = StalledReconnectDetector();
    expect(observe(d, 0, bytes: 100, positionMs: 10000), isFalse);
    expect(observe(d, 50, bytes: 200, positionMs: 1000), isFalse);
    expect(observe(d, 169, bytes: 200, positionMs: 1000), isFalse);
    expect(observe(d, 170, bytes: 200, positionMs: 1000), isTrue);
  });
}
