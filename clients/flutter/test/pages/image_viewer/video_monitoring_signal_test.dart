// Юнит-стражи клиентского детектора видео-проблем для комнаты «Liza · Видео»:
// сессионный агрегатор ребуферинга (`VideoRebufferAggregator`), бакет размера
// (`videoSizeBucket`) и PII-safe title видео-сигнала (`Monitoring.videoIssueTitle`).
// Реальный libmpv/ребуфер/провал на устройстве — device/manual (AC-7).
//
// Реестр: tests/registry/RL-video-playback-monitoring-signal.md
// Дизайн: docs/superpowers/specs/2026-08-26-video-playback-monitoring-alerts-design.md
//
// ledger:RL-video-playback-monitoring-signal

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/image_viewer/video_player.dart';
import 'package:liza/utils/monitoring.dart';

void main() {
  final t0 = DateTime(2026, 8, 26, 12, 0, 0);

  group('VideoRebufferAggregator.observe — порог ≥3/30с (AC-3)', () {
    // AC:RL-video-playback-monitoring-signal/3
    test('AC-3: <3 за 30с → 0 сигналов', () {
      final agg = VideoRebufferAggregator();
      expect(agg.observe(t0), isFalse);
      expect(agg.observe(t0.add(const Duration(seconds: 5))), isFalse);
      expect(agg.pendingCount, 2);
    });

    // AC:RL-video-playback-monitoring-signal/3
    test('AC-3: ровно 3 за 30с → РОВНО 1 сигнал (третий тик)', () {
      final agg = VideoRebufferAggregator();
      expect(agg.observe(t0), isFalse);
      expect(agg.observe(t0.add(const Duration(seconds: 10))), isFalse);
      expect(agg.observe(t0.add(const Duration(seconds: 20))), isTrue); // порог
      // дальше — тишина: сигнал за сессию уже ушёл, чат не спамим
      expect(agg.observe(t0.add(const Duration(seconds: 25))), isFalse);
      expect(agg.observe(t0.add(const Duration(seconds: 26))), isFalse);
    });

    // AC:RL-video-playback-monitoring-signal/3
    test('AC-3 red-proof: 3 андеррана, растянутых на >30с → 0 сигналов', () {
      final agg = VideoRebufferAggregator();
      expect(agg.observe(t0), isFalse);
      expect(agg.observe(t0.add(const Duration(seconds: 20))), isFalse);
      // третий — через 40с от первого: первый выпал из окна, в окне только 2
      expect(agg.observe(t0.add(const Duration(seconds: 40))), isFalse);
      expect(agg.pendingCount, 2);
    });

    // AC:RL-video-playback-monitoring-signal/3
    test('reset() возвращает агрегатор к нулю (повторная попытка)', () {
      final agg = VideoRebufferAggregator();
      agg.observe(t0);
      agg.observe(t0.add(const Duration(seconds: 1)));
      expect(agg.observe(t0.add(const Duration(seconds: 2))), isTrue);
      agg.reset();
      expect(agg.pendingCount, 0);
      // после reset снова можно набрать порог и получить сигнал
      agg.observe(t0.add(const Duration(minutes: 5)));
      agg.observe(t0.add(const Duration(minutes: 5, seconds: 1)));
      expect(agg.observe(t0.add(const Duration(minutes: 5, seconds: 2))), isTrue);
    });
  });

  group('videoRebufferReason — причина по замеру, не по допущению (AC-16)', () {
    // AC:RL-video-playback-monitoring-signal/16 — кейс #2146: 10-МБ файл, байты
    // приходят быстро (5 МБ/с ≫ битрейта), а плеер стоит → НЕ slow-network.
    test('AC-16: вход быстрее битрейта → local-stall', () {
      expect(
        videoRebufferReason(
          inputBytesPerSec: 5 * 1024 * 1024,
          sizeBytes: 10 * 1024 * 1024,
          durationMs: 30000,
        ),
        'local-stall',
      );
    });

    // AC:RL-video-playback-monitoring-signal/16
    test('AC-16: вход медленнее битрейта → slow-network', () {
      // 10 МБ / 30 с ≈ 350 КБ/с нужно, приходит 100 КБ/с.
      expect(
        videoRebufferReason(
          inputBytesPerSec: 100 * 1024,
          sizeBytes: 10 * 1024 * 1024,
          durationMs: 30000,
        ),
        'slow-network',
      );
    });

    // AC:RL-video-playback-monitoring-signal/16
    test('AC-16: нет size/duration → порог 1 МБ/с', () {
      expect(videoRebufferReason(inputBytesPerSec: 200 * 1024), 'slow-network');
      expect(
        videoRebufferReason(inputBytesPerSec: 2 * 1024 * 1024),
        'local-stall',
      );
      expect(
        videoRebufferReason(inputBytesPerSec: 2 * 1024 * 1024, durationMs: 0),
        'local-stall',
      );
    });

    // AC:RL-video-playback-monitoring-signal/16 — без замера не угадываем.
    test('AC-16: замера нет (null/отрицательный) → rate-unknown', () {
      expect(videoRebufferReason(sizeBytes: 1, durationMs: 1), 'rate-unknown');
      expect(videoRebufferReason(inputBytesPerSec: -1), 'rate-unknown');
    });

    // AC:RL-video-playback-monitoring-signal/16 — ∀ reason ребуфера голова и
    // самые ценные поля контекста влезают в бюджет title.
    test(
      'AC-16 ∀: по всем reason ребуфера title ≤ бюджета и несёт e2ee/size',
      () {
        for (final reason in ['slow-network', 'local-stall', 'rate-unknown']) {
          final title = Monitoring.buildAlertTitle(
            prefix: Monitoring.videoRebufferPrefix,
            reason: reason,
            host: 'synapse.liza.laba.prodamus.tech',
            context: {
              'e2ee': 'true',
              'mime': 'video/mp4',
              'size': '<10MB',
              'platform': 'android',
              'mmr': 'true',
            },
          );
          expect(
            title.length,
            lessThanOrEqualTo(Monitoring.maxAlertTitleLength),
          );
          expect(
            title,
            startsWith(
              '[video-rebuffer] reason=$reason host=synapse.liza e2ee=true',
            ),
          );
          expect(title, contains('size=<10MB'), reason: reason);
        }
      },
    );
  });

  group('Свап-сигнал гейтится хостом + инертность (AC-2/AC-5)', () {
    // AC:RL-video-playback-monitoring-signal/2
    test('AC-2: свап сигналим ТОЛЬКО на MMR-хосте (гейт _reportVideoSwap)', () {
      // _reportVideoSwap: `if (!isMmrBackedHost(host)) return;` — сигнал только
      // когда медиа обслуживает MMR (там свап аномалия). На не-MMR свап штатен.
      expect(
        EventVideoPlayerState.isMmrBackedHost('synapse.liza.laba.prodamus.tech'),
        isTrue,
      );
      expect(EventVideoPlayerState.isMmrBackedHost('liza.cyber-agro.ru'), isFalse);
      expect(EventVideoPlayerState.isMmrBackedHost('nadezhda.liza.ru'), isFalse);
      expect(EventVideoPlayerState.isMmrBackedHost(null), isFalse);
    });

    // AC:RL-video-playback-monitoring-signal/5
    test('AC-5: reportVideoIssue при !isActive — no-op, не бросает', () {
      // Monitoring не инициализирован в тестах → _active=false → полный no-op.
      expect(Monitoring.isActive, isFalse);
      expect(
        () => Monitoring.reportVideoIssue(
          prefix: Monitoring.videoSwapPrefix,
          reason: 'swap-to-local',
          host: 'synapse.liza.laba.prodamus.tech',
          context: const {'e2ee': 'false', 'size': '>150MB'},
        ),
        returnsNormally,
      );
    });
  });

  group('videoSizeBucket — низкая кардинальность', () {
    test('бакеты по границам 10/50/150 МБ', () {
      expect(videoSizeBucket(null), 'unknown');
      expect(videoSizeBucket(5 * 1024 * 1024), '<10MB');
      expect(videoSizeBucket(30 * 1024 * 1024), '10-50MB');
      expect(videoSizeBucket(100 * 1024 * 1024), '50-150MB');
      expect(videoSizeBucket(161 * 1024 * 1024), '>150MB');
    });
  });

  group('Monitoring.videoIssueTitle — маркер + reason + host, БЕЗ секретов (AC-4)', () {
    // AC:RL-video-playback-monitoring-signal/4  AC:RL-mediadiag-no-secret/video-fail
    test('AC-4: title несёт префикс+reason+host и НЕ несёт ключ/iv/токен/eventId', () {
      final title = Monitoring.videoIssueTitle(
        Monitoring.videoSwapPrefix,
        'swap-to-local',
        'synapse.liza.laba.prodamus.tech',
      );
      expect(title, contains('[video-swap]'));
      expect(title, contains('reason=swap-to-local'));
      // host — короткой формой (бюджет 99 символов GlitchTip, см.
      // `Monitoring.shortHost`); инстанс по ней по-прежнему однозначен.
      expect(title, contains('host=synapse.liza'));
      expect(title.length, lessThanOrEqualTo(Monitoring.maxAlertTitleLength));
      // Ни один секрет-маркер не присутствует (red-proof: добавление eventId/
      // token/key в title краснит этот ассерт).
      for (final forbidden in const [
        'key=',
        'iv=',
        'Bearer',
        'token',
        'authorization',
        r'$event',
        'access_token',
      ]) {
        expect(title.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
      }
    });

    // AC:RL-video-playback-monitoring-signal/10 — терминальный провал видео идёт
    // в GlitchTip как ИСКЛЮЧЕНИЕ, и его title = `toString()` с добавленным
    // Sentry именем класса. Прежняя форма дублировала имя класса и обрывалась
    // посреди host'а (прод-БД 2026-09-10: 4 issue ровно на 100 символов).
    test('AC-10: title [video-fail] — маркер+reason+host переживают обрез '
        'GlitchTip (нет дубля имени класса, host короткий)', () {
      const sentryPrefix = 'VideoPlaybackException: '; // добавляет Sentry SDK
      final value = VideoPlaybackException(
        'Unable to play video',
        reason: 'stalled-reconnect',
        host: 'synapse.liza.laba.prodamus.tech',
        cause: 'libmpv cplayer: Cannot seek in this stream.',
      ).toString();
      // Имя класса в теле НЕ повторяем — Sentry ставит его сам.
      expect(value, isNot(contains('VideoPlaybackException')));
      expect(value, startsWith('[video-fail] reason=stalled-reconnect host=synapse.liza'));
      // Триаж-критичная голова доезжает целой ДАЖЕ после обреза на 100.
      final asTitle = '$sentryPrefix$value';
      final delivered = asTitle.length <= 100 ? asTitle : asTitle.substring(0, 99);
      expect(delivered, contains('[video-fail]'));
      expect(delivered, contains('reason=stalled-reconnect'));
      expect(delivered, contains('host=synapse.liza'));
      // eventId (локатор контента) в сигнал не уходит — пин RL-mediadiag-no-secret.
      expect(value, isNot(contains(r'$')));
    });

    // AC:RL-video-playback-monitoring-signal/10 — МУЛЬТИКЕЙС ∀: один пример дал бы
    // ложно-зелёный, а бюджет ломает именно САМЫЙ ДЛИННЫЙ reason.
    test('AC-10 ∀: по ВСЕМ реальным reason видео-провала голова сигнала '
        '(маркер+reason+host) переживает обрез GlitchTip на 100', () {
      // Все литералы reason из video_player.dart (включая _fatalReasonFor).
      const reasons = [
        'stalled-reconnect',
        'watchdog-no-progress',
        'swap-to-local',
        'slow-network',
        'io-error',
        'open-failed',
        'unable-to-play',
        'poster-extract-fail',
        'libmpv-fatal',
        'http-5xx',
        'http-4xx',
        'unknown',
      ];
      const sentryPrefix = 'VideoPlaybackException: ';
      for (final reason in reasons) {
        final value = VideoPlaybackException(
          'Unable to play video',
          reason: reason,
          host: 'synapse.liza.laba.prodamus.tech',
        ).toString();
        final head = '$sentryPrefix[video-fail] reason=$reason host=synapse.liza';
        expect(
          head.length,
          lessThanOrEqualTo(99),
          reason: 'голова сигнала не влезает в обрез GlitchTip: reason=$reason',
        );
        expect('$sentryPrefix$value', startsWith(head));
      }
    });

    // AC:RL-monitoring-notifier-video-routing/8 (клиентская половина контракта)
    test('маркеры префиксов стабильны — контракт с notifier', () {
      expect(Monitoring.videoFailurePrefix, '[video-fail]');
      expect(Monitoring.videoSwapPrefix, '[video-swap]');
      expect(Monitoring.videoRebufferPrefix, '[video-rebuffer]');
    });

    test('host=null → unknown (не пустой хвост, дедуп стабилен)', () {
      final title = Monitoring.videoIssueTitle(
        Monitoring.videoRebufferPrefix,
        'slow-network',
        null,
      );
      expect(title, contains('host=unknown'));
    });
  });

  group('alertHostFor — origin-приоритет (AC-8, фикс федеративной слепоты)', () {
    // AC:RL-video-playback-monitoring-signal/8
    test('AC-8: origin ≠ homeserver → в алёрт идёт ORIGIN, не homeserver читателя',
        () {
      // Федеративное видео: origin=user.liza.ru, читатель на synapse.liza.laba…
      // Red-proof: при возврате к homeserver-приоритету (homeserver ?? origin)
      // этот ассерт краснеет — origin бы не попал в алёрт.
      expect(
        alertHostFor('user.liza.ru', 'synapse.liza.laba.prodamus.tech'),
        'user.liza.ru',
      );
    });

    // AC:RL-video-playback-monitoring-signal/8
    test('AC-8: origin пуст (не-медиа/битый mxc) → фолбэк на homeserver', () {
      expect(alertHostFor(null, 'synapse.liza.laba.prodamus.tech'),
          'synapse.liza.laba.prodamus.tech');
    });

    // AC:RL-video-playback-monitoring-signal/8
    test('AC-8: оба пусты → null (не падаем)', () {
      expect(alertHostFor(null, null), isNull);
    });
  });

  group('buildSentryUser — личность в scope, НЕ в title (AC-9)', () {
    // AC:RL-video-playback-monitoring-signal/9
    test('AC-9: mxid → id полный, username = localpart (без :server), name = null',
        () {
      final u = Monitoring.buildSentryUser(
        '@dmitrii.luba:synapse.liza.laba.prodamus.tech',
      );
      expect(u.id, '@dmitrii.luba:synapse.liza.laba.prodamus.tech');
      expect(u.username, 'dmitrii.luba'); // localpart, без :server
      expect(u.name, isNull);
    });

    // AC:RL-video-playback-monitoring-signal/9
    test('AC-9: display name (best-effort) прокидывается в name', () {
      final u = Monitoring.buildSentryUser('@a:h', displayName: 'Иван Петров');
      expect(u.name, 'Иван Петров');
      expect(u.username, 'a');
    });

    // AC:RL-video-playback-monitoring-signal/9
    test('AC-9: невалидный mxid (нет @/:) не роняет — id как есть', () {
      final u = Monitoring.buildSentryUser('garbage');
      expect(u.id, 'garbage');
      expect(u.username, 'garbage');
    });

    // AC:RL-video-playback-monitoring-signal/9
    test(
        'AC-9 red-proof: title-билдеры (то, что доезжает в чат) НЕ несут '
        'личность — только prefix/reason/host', () {
      // Личность живёт в SentryUser (scope), а title строится из (prefix,reason,
      // host). Red-proof: если билдер начнёт подмешивать mxid/localpart —
      // краснеет isNot(contains('@')) и проверка localpart.
      const mxid = '@dmitrii.luba:synapse.liza.laba.prodamus.tech';
      final vTitle = Monitoring.videoIssueTitle(
        Monitoring.videoFailurePrefix,
        'stalled-reconnect',
        'user.liza.ru',
      );
      final aTitle = Monitoring.audioIssueTitle(
        Monitoring.audioFailurePrefix,
        'playback-error',
        'user.liza.ru',
      );
      for (final title in [vTitle, aTitle]) {
        expect(title, isNot(contains('@')));
        expect(title, isNot(contains('dmitrii.luba')));
        expect(title, isNot(contains(mxid)));
      }
    });
  });


  // AC:RL-video-playback-monitoring-signal/11 — `[video-swap]` несёт ТРИГГЕР свапа.
  // #2063 (2026-09-24): константный `reason=swap-to-local` не говорил, какой
  // детектор сорвал живой, но медленный стрим — корень не разбирался.
  group('AC-11: [video-swap] несёт триггер свапа', () {
    test('AC-11: ∀ точек входа в _swapToLocal передают триггер, в title — он, '
        'а не константа', () {
      final src = File(
        'lib/pages/image_viewer/video_player.dart',
      ).readAsStringSync();
      // Только места ВЫЗОВА (объявление метода несёт `required String trigger`).
      final calls = RegExp(
        r'(?:await |unawaited\()_swapToLocal\(([^)]*)\)',
      ).allMatches(src).toList();
      // watchdog + _handlePlaybackError — обе известные точки входа.
      expect(calls.length, greaterThanOrEqualTo(2));
      for (final c in calls) {
        expect(
          c.group(1),
          contains('trigger:'),
          reason: 'вызов без триггера вернёт безликий [video-swap]: ${c.group(0)}',
        );
      }
      expect(src, isNot(contains("reason: 'swap-to-local'")));
      expect(src, contains('reason: trigger'));
    });

    test('AC-11 ∀: с самым длинным триггером голова+контекст e2ee/mime/size '
        'укладываются в бюджет title', () {
      const triggers = [
        'watchdog-no-progress',
        'stalled-reconnect',
        'unable-to-play',
        'open-failed',
        'libmpv-fatal',
        'http-5xx',
      ];
      for (final t in triggers) {
        final title = Monitoring.buildAlertTitle(
          prefix: Monitoring.videoSwapPrefix,
          reason: t,
          host: 'synapse.liza.laba.prodamus.tech',
          context: const {
            'e2ee': 'false',
            'mime': 'video/mp4',
            'size': '50-150MB',
            'platform': 'ios',
            'mmr': 'true',
          },
        );
        expect(title, startsWith('[video-swap] reason=$t host=synapse.liza'));
        expect(title, contains('size=50-150MB'), reason: t);
        expect(title.length, lessThanOrEqualTo(Monitoring.maxAlertTitleLength));
      }
    });
  });
}
