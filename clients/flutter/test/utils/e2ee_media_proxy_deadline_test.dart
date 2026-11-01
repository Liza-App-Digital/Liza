// Настоящий production deadline; fake clock меняет только ход времени.
// ledger:RL-e2ee-video-proxy-resume
// ledger:RL-video-stream-progress-and-lifecycle
// guard.render: unit
// ignore_for_file: depend_on_referenced_packages
import 'dart:ui' show AppLifecycleState;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/e2ee_media_proxy.dart';
import 'package:liza/utils/foreground_witness.dart';

void main() {
  // AC:RL-e2ee-video-proxy-resume/10
  // AC:RL-video-stream-progress-and-lifecycle/1
  for (final interval in [2, 59]) {
    test(
      'валидный chunk каждые $interval с, ≥240 с: body60/recovery120 не истекают',
      () {
        fakeAsync((async) {
          final body = E2eeProxyDeadline(
            const Duration(seconds: 60),
            null,
            stopwatch: async.getClock(DateTime(2026)).stopwatch(),
          )..resume();
          final progress = E2eeProxyDeadline(
            const Duration(seconds: 120),
            null,
            stopwatch: async.getClock(DateTime(2026)).stopwatch(),
          )..resume();
          for (var elapsed = 0; elapsed < 240; elapsed += interval) {
            async.elapse(Duration(seconds: interval));
            expect(body.expired, false);
            expect(progress.expired, false);
            body.reset();
            progress.reset();
          }
          body.dispose();
          progress.dispose();
        });
      },
    );
  }
  // AC:RL-e2ee-video-proxy-resume/9
  // AC:RL-video-stream-progress-and-lifecycle/3
  // AC:RL-video-stream-progress-and-lifecycle/14
  for (final seconds in [30, 60, 120]) {
    test('без прогресса deadline $seconds с истекает ровно на границе', () {
      fakeAsync((async) {
        final deadline = E2eeProxyDeadline(
          Duration(seconds: seconds),
          null,
          stopwatch: async.getClock(DateTime(2026)).stopwatch(),
        )..resume();
        async.elapse(Duration(seconds: seconds - 1));
        expect(deadline.expired, false);
        async.elapse(const Duration(seconds: 1));
        expect(deadline.expired, true);
        deadline.dispose();
      });
    });
  }
  // AC:RL-e2ee-video-proxy-resume/11
  // AC:RL-video-stream-progress-and-lifecycle/5
  test('сон180с: 0 expiry; resume даёт полный120с + grace5с', () {
    fakeAsync((async) {
      final witness = ForegroundWitness.manual(
        initial: AppLifecycleState.resumed,
      );
      final deadline = E2eeProxyDeadline(
        const Duration(seconds: 120),
        witness,
        stopwatch: async.getClock(DateTime(2026)).stopwatch(),
      )..resume();
      async.elapse(const Duration(seconds: 119));
      witness.onStateChange(AppLifecycleState.paused);
      async.elapse(const Duration(seconds: 180));
      expect(deadline.expired, false);
      witness.onStateChange(AppLifecycleState.resumed);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 124));
      expect(deadline.expired, false);
      async.elapse(const Duration(seconds: 1));
      expect(deadline.expired, true);
      deadline.dispose();
      witness.dispose();
      async.flushMicrotasks();
    });
  });
  // AC:RL-e2ee-video-proxy-resume/12
  test(
    'backpressure180с не расходует body idle; после demand остаётся прежний остаток',
    () {
      fakeAsync((async) {
        final deadline = E2eeProxyDeadline(
          const Duration(seconds: 60),
          null,
          stopwatch: async.getClock(DateTime(2026)).stopwatch(),
        )..resume();
        async.elapse(const Duration(seconds: 20));
        deadline.pause();
        async.elapse(const Duration(seconds: 180));
        expect(deadline.expired, false);
        deadline.resume();
        async.elapse(const Duration(seconds: 39));
        expect(deadline.expired, false);
        async.elapse(const Duration(seconds: 1));
        expect(deadline.expired, true);
        deadline.dispose();
      });
    },
  );
}
