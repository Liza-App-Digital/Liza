import 'dart:async';
import 'dart:io';

import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/foreground_witness.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/widgets/mxc_image.dart';

/// ledger:RL-media-stuck-load-watchdog
///
/// Класс «тихий вечный спиннер»: `MxcImage._load` await'ил download/decrypt БЕЗ
/// таймаута → зависший await (сервер не отдаёт байты, исключения нет) не доходил
/// до `catch` в `_tryLoad` → `_failed` не ставился, `_recordGiveUp` не звался →
/// вечный `placeholder()`, ноль телеметрии. Баг Петра (пересланная галерея: 2/3
/// плитки крутят спиннер вечно, в логе 0 медиа-ошибок) — этого класса.
///
/// Фикс: watchdog-таймаут на сетевую фазу (thumb 20с / full 60с) → существующий
/// `_failed`+tap-to-retry + маркированный сигнал `[media-stuck]` (роутится в
/// «Liza · Медиа»). Здесь застражены ЧИСТЫЕ поверхности решения: агрегатор
/// (leading-edge + дедуп + маркер + PII-safe), классификатор reason и предикат
/// смены identity (защита от γ-ложняка). Тайминг `.timeout()`→`_failed` и
/// кнопка «Повторить» — device/manual (RL: AC-2/AC-3/AC-6-widget).
void main() {
  group('mediaStuckReasonFor — закрытый перечень (AC-1 reason)', () {
    test('TimeoutException → stuck-timeout (зависший await)', () {
      // AC:RL-media-stuck-load-watchdog/1
      expect(mediaStuckReasonFor(TimeoutException('x')), 'stuck-timeout');
    });

    test('иное исключение → give-up (исчерпаны ретраи)', () {
      expect(mediaStuckReasonFor(Exception('boom')), 'give-up');
      expect(mediaStuckReasonFor(StateError('s')), 'give-up');
    });
  });

  group('MediaStuckAggregator — leading-edge + дедуп + маркер', () {
    test('AC-1: первая сдача в окне эмитит ровно один сигнал', () {
      final agg = MediaStuckAggregator(now: () => DateTime(2026, 9, 1, 10));
      final msg = agg.onGiveUp('stuck-timeout', 'user.liza.ru');
      expect(msg, isNotNull);
    });

    test('AC-5: сигнал несёт маркер [media-stuck] + host, БЕЗ media_id (PII)', () {
      // AC:RL-media-stuck-load-watchdog/5
      final agg = MediaStuckAggregator(now: () => DateTime(2026, 9, 1, 10));
      final msg = agg.onGiveUp('stuck-timeout', 'user.liza.ru')!;
      // Маркер обязателен — иначе notifier не сроутит в «Liza · Медиа».
      expect(msg, startsWith('[media-stuck]'));
      expect(msg, contains('reason=stuck-timeout'));
      // host — короткой формой: длинный + прежнее длинное пояснение выталкивали
      // сигнал за 100-символьный предел title GlitchTip (обрубок «вечный спи…»).
      expect(msg, contains('host=user.liza'));
      expect(msg.length, lessThanOrEqualTo(Monitoring.maxAlertTitleLength));
      // PII-safe: только server_name, никаких mxc/media_id в сигнале.
      expect(msg.contains('mxc://'), isFalse);
    });

    test('host отсутствует → сигнал без host-части (не падаем, не пишем null)',
        () {
      final agg = MediaStuckAggregator(now: () => DateTime(2026, 9, 1, 10));
      final msg = agg.onGiveUp('give-up', null)!;
      expect(msg, startsWith('[media-stuck]'));
      expect(msg.contains('host='), isFalse);
      expect(msg.contains('null'), isFalse);
    });

    test('AC-4 (red-proof): N сдач в одном окне → ровно ОДИН сигнал (дедуп)', () {
      var now = DateTime(2026, 9, 1, 10);
      final agg = MediaStuckAggregator(now: () => now);
      final emitted = <String>[];
      // AC:RL-media-stuck-load-watchdog/4
      // Обрыв сети: 10 плиток галереи таймаутят почти одновременно.
      for (var i = 0; i < 10; i++) {
        now = now.add(const Duration(seconds: 1));
        final m = agg.onGiveUp('stuck-timeout', 'user.liza.ru');
        if (m != null) emitted.add(m);
      }
      expect(emitted.length, 1); // leading-edge: не лавина из 10
    });

    test('AC-6 (ядро): по истечении окна защёлка снимается → новый сигнал', () {
      // AC:RL-media-stuck-load-watchdog/6
      var now = DateTime(2026, 9, 1, 10);
      final agg = MediaStuckAggregator(now: () => now);
      expect(agg.onGiveUp('stuck-timeout', 'a'), isNotNull); // окно 1
      expect(agg.onGiveUp('stuck-timeout', 'a'), isNull); // дедуп
      now = now.add(MediaStuckAggregator.window + const Duration(seconds: 1));
      expect(agg.onGiveUp('stuck-timeout', 'a'), isNotNull); // окно 2 — снова
    });
  });

  group('give-up несёт класс ошибки (issue #2059)', () {
    // Серверы за окно сдачи не получили ни одного медиа-запроса — причина
    // осталась только на устройстве. Без kind/err алёрт не отвечал на «почему»
    // и врал «без ошибки».
    MediaStuckAggregator fresh() =>
        MediaStuckAggregator(now: () => DateTime(2026, 9, 23, 14));

    test('AC-8: give-up → kind=<класс>, без приписки «без ошибки»', () {
      // AC:RL-media-stuck-load-watchdog/8
      final msg = fresh().onGiveUp(
        'give-up',
        'liza.cyber-agro.ru',
        error: const SocketException('Connection failed'),
      )!;
      expect(
        msg,
        '[media-stuck] reason=give-up host=liza.cyber-agro kind=network',
      );
      expect(msg.contains('без ошибки'), isFalse);
      expect(msg.contains('Connection failed'), isFalse); // текст ошибки не берём
    });

    test('AC-8: stuck-timeout сохраняет приписку «вечный спиннер без ошибки»',
        () {
      final msg = fresh().onGiveUp(
        'stuck-timeout',
        'liza.cyber-agro.ru',
        error: TimeoutException('x'),
      )!;
      expect(msg, endsWith('(вечный спиннер без ошибки)'));
      expect(msg.contains('kind='), isFalse);
    });

    test('AC-9: kind=other → err=<тип>, без текста ошибки', () {
      // AC:RL-media-stuck-load-watchdog/9
      final msg = fresh().onGiveUp(
        'give-up',
        'liza.cyber-agro.ru',
        error: StateError('mxc://liza.cyber-agro.ru/secretMediaId'),
      )!;
      expect(msg, endsWith(' kind=other err=StateError'));
      expect(msg.contains('mxc://'), isFalse);
      expect(msg.contains('secretMediaId'), isFalse);
    });

    test('AC-9: длинный тип подрезается в бюджет title, голова цела', () {
      final msg = fresh().onGiveUp(
        'give-up',
        'nadezhda.liza.ru',
        error: _AVeryLongCustomExceptionTypeNameForBudget(),
      )!;
      expect(msg.length, lessThanOrEqualTo(Monitoring.maxAlertTitleLength));
      expect(
        msg,
        startsWith(
          '[media-stuck] reason=give-up host=nadezhda.liza kind=other err=_AVery',
        ),
      );
    });

    test('AC-9: хост из mxc на весь бюджет title — без RangeError', () {
      final label = 'a' * 63;
      final msg = fresh().onGiveUp(
        'give-up',
        '$label.$label.evil',
        error: _AVeryLongCustomExceptionTypeNameForBudget(),
      )!;
      expect(msg, contains(' kind=other err='));
      expect(msg, contains('host=$label.$label'));
    });
  });

  group('attachmentIdentityChanged — защита от γ (AC-7)', () {
    test('смена uri → identity изменилась (перезапуск загрузки)', () {
      // AC:RL-media-stuck-load-watchdog/7
      final a = MxcImage(uri: Uri.parse('mxc://s/aaa'));
      final b = MxcImage(uri: Uri.parse('mxc://s/bbb'));
      expect(MxcImage.attachmentIdentityChanged(a, b), isTrue);
    });

    test('смена cacheKey → identity изменилась', () {
      final a = MxcImage(uri: Uri.parse('mxc://s/aaa'), cacheKey: 'k1');
      final b = MxcImage(uri: Uri.parse('mxc://s/aaa'), cacheKey: 'k2');
      expect(MxcImage.attachmentIdentityChanged(a, b), isTrue);
    });

    test('всё то же → identity НЕ изменилась (нет лишнего перезапуска)', () {
      final a = MxcImage(uri: Uri.parse('mxc://s/aaa'), cacheKey: 'k1');
      final b = MxcImage(uri: Uri.parse('mxc://s/aaa'), cacheKey: 'k1');
      expect(MxcImage.attachmentIdentityChanged(a, b), isFalse);
    });
  });

  group('holdRetryForSuspension — сон не сжигает ретраи (AC-11)', () {
    // GlitchTip #2166 (iOS 3789): `resumed` 09:42:04 → give-up kind=network
    // 09:42:11, сервер чист. Просроченные во сне таймеры backoff выстреливают
    // скопом, сокеты мёртвые — все 5 попыток падают за секунды.
    ForegroundWitness fresh(AppLifecycleState s) =>
        ForegroundWitness.manual(initial: s);

    test('сбой в первые секунды после пробуждения → ретрай придержан', () {
      // AC:RL-media-stuck-load-watchdog/11
      final w = fresh(AppLifecycleState.paused)
        ..onStateChange(AppLifecycleState.resumed);
      expect(holdRetryForSuspension(const SocketException('x'), w, 0), isTrue);
      expect(holdRetryForSuspension(TimeoutException('x'), w, 1), isTrue);
    });

    test('потолок: после maxSuspensionPasses пропусков — обычный ретрай', () {
      // AC:RL-media-stuck-load-watchdog/11
      final w = fresh(AppLifecycleState.paused);
      expect(
        holdRetryForSuspension(
          const SocketException('x'),
          w,
          maxSuspensionPasses,
        ),
        isFalse,
      );
    });

    test(
      'процесс на экране и не в окне после сна → честный сбой, не придержан',
      () {
        // AC:RL-media-stuck-load-watchdog/11
        final w = fresh(AppLifecycleState.resumed);
        expect(
          holdRetryForSuspension(const SocketException('x'), w, 0),
          isFalse,
        );
      },
    );

    test('не транспорт (HTTP/decrypt/other) и нет witness → не придержан', () {
      // AC:RL-media-stuck-load-watchdog/11
      final w = fresh(AppLifecycleState.paused);
      expect(holdRetryForSuspension(StateError('x'), w, 0), isFalse);
      expect(
        holdRetryForSuspension(const SocketException('x'), null, 0),
        isFalse,
      );
    });
  });
}

class _AVeryLongCustomExceptionTypeNameForBudget implements Exception {}
