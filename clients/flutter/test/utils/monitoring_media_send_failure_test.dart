// Стражи сигнала провала отправки вложений `[media-send-fail]` и фильтра шагов
// для справки поддержки. ∀ по стадиям × классам причины × типам набора — один
// пример дал бы ложно-зелёный бюджет title.
//
// Реальный сигнал с устройства — manual (нужна нативная сборка).
// Дизайн: docs/superpowers/specs/2026-10-19-support-client-diagnostics-design.md
//
// ledger:RL-media-send-failure-signal

import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:liza/utils/monitoring.dart';

class VideoFileNameLeakCanaryImg20261019X123109 implements Exception {
  @override
  String toString() =>
      'PathNotFound /storage/emulated/0/DCIM/книга_Тимура.mp4 @braslavna:server';
}

void main() {
  const reasons = ['upload', 'prepare', 'dialog', 'share'];
  const kinds = ['network', 'server', 'disk', 'unknown'];
  const media = ['image', 'video', 'audio', 'file', 'mixed'];

  test('title ≤ 99, префикс и reason на месте ∀ комбинаций', () {
    // AC:RL-media-send-failure-signal/1
    for (final r in reasons) {
      for (final k in kinds) {
        for (final m in media) {
          final title = Monitoring.mediaSendTitle(
            reason: r,
            kind: k,
            media: m,
            host: 'synapse.liza.laba.prodamus.tech',
            error: VideoFileNameLeakCanaryImg20261019X123109(),
            notSent: 23,
            total: 30,
          );
          expect(
            title.length,
            lessThanOrEqualTo(Monitoring.maxAlertTitleLength),
          );
          expect(title, startsWith('[media-send-fail] reason=$r '));
          // Маркер маршрутизации notifier в «Liza · Медиа».
          expect(title, startsWith('[media-'));
          // Иначе fleet-poller примет событие за heartbeat.
          expect(title, isNot(contains('env=')));
        }
      }
    }
  });

  test('ни имени файла, ни пути, ни mxid — только имя типа ошибки', () {
    // AC:RL-media-send-failure-signal/2
    final title = Monitoring.mediaSendTitle(
      reason: 'prepare',
      kind: 'unknown',
      media: 'video',
      error: VideoFileNameLeakCanaryImg20261019X123109(),
    );
    for (final leak in ['книга', '.mp4', '/storage', '@braslavna', 'DCIM']) {
      expect(title, isNot(contains(leak)));
    }
    expect(title, endsWith('err=VideoFileNameLeakCanaryImg2026'));
    // При известном классе тип ошибки не нужен и не пишется.
    expect(
      Monitoring.mediaSendTitle(
        reason: 'upload',
        kind: 'network',
        media: 'video',
        error: VideoFileNameLeakCanaryImg20261019X123109(),
        notSent: 1,
        total: 3,
      ),
      '[media-send-fail] reason=upload host=unknown kind=network media=video n=1/3',
    );
  });

  test('троттл per-reason 5 минут', () {
    // AC:RL-media-send-failure-signal/3
    Monitoring.resetMediaSendThrottle();
    final t0 = DateTime(2026, 10, 19, 12);
    expect(Monitoring.mediaSendThrottleAllows('upload', t0), isTrue);
    expect(
      Monitoring.mediaSendThrottleAllows(
        'upload',
        t0.add(const Duration(minutes: 4)),
      ),
      isFalse,
    );
    expect(Monitoring.mediaSendThrottleAllows('prepare', t0), isTrue);
    expect(
      Monitoring.mediaSendThrottleAllows(
        'upload',
        t0.add(const Duration(minutes: 5)),
      ),
      isTrue,
    );
    Monitoring.resetMediaSendThrottle();
  });

  test('без DSN — no-op, не бросает', () {
    // AC:RL-media-send-failure-signal/3
    expect(Monitoring.isActive, isFalse);
    Monitoring.reportMediaSendFailure(
      reason: 'dialog',
      kind: 'unknown',
      media: 'video',
      error: Exception('x'),
    );
    Monitoring.breadcrumb('send', 'start media=video n=1');
  });

  test('тип набора', () {
    expect(Monitoring.mediaTypeOf(['image/jpeg', 'image/png']), 'image');
    expect(Monitoring.mediaTypeOf(['video/mp4']), 'video');
    expect(Monitoring.mediaTypeOf(['application/pdf', null]), 'file');
    expect(Monitoring.mediaTypeOf(['image/jpeg', 'video/mp4']), 'mixed');
    expect(Monitoring.mediaTypeOf(const []), 'file');
  });

  test('шаги: проходят только allowlist-категории', () {
    // AC:RL-media-send-failure-signal/4
    for (final ok in Monitoring.breadcrumbCategories) {
      final crumb = Breadcrumb(category: ok, message: 'x');
      expect(Monitoring.filterBreadcrumb(crumb, Hint()), same(crumb));
    }
    // Крошки mpv видео-плеера — контекст `[video-*]`, их фильтр резать не должен.
    final mpv = Breadcrumb(category: 'media_kit', message: 'mpv recoverable');
    expect(Monitoring.filterBreadcrumb(mpv, Hint()), same(mpv));
    for (final drop in [
      'http',
      'navigation',
      'ui.click',
      'console',
      null,
    ]) {
      expect(
        Monitoring.filterBreadcrumb(
          Breadcrumb(category: drop, message: 'rooms/!secret:server'),
          Hint(),
        ),
        isNull,
        reason: '$drop',
      );
    }
    expect(Monitoring.filterBreadcrumb(null, Hint()), isNull);
  });
}
