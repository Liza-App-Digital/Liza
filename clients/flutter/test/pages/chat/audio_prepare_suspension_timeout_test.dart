// Страж «сбой подготовки аудио из-за сна процесса — не авария, а реальный сбой
// на глазах пользователя — авария» (RL-audio-prepare-no-dead-window, AC-10…AC-16).
//
// Инцидент 2026-09-15 (GlitchTip #2025): приложение ушло в фон посреди
// скачивания m4a 26 МБ, iOS заморозил процесс, дедлайн выстрелил при фоновом
// пробуждении через 11 минут → красный `[audio-fail] reason=prepare-timeout`,
// хотя MMR отдавал файл исправно.
//
// Проверяемая величина — ТИП исключения `withForegroundDeadline`, по которому
// вызывающие (`AudioPlayerState._downloadAndPlay`,
// `AudioAutoPlayService._playEvent`) решают, слать ли алёрт и SnackBar.
// Переходы lifecycle идут по соседним состояниям: `AppLifecycleListener` в debug
// проверяет валидность перехода.
//
// Red-proof: на голом `.timeout()` краснеют AC-10/AC-11; на первой версии фикса
// (залипающий флаг «был в фоне», f8d9bab6) краснеет AC-14 — мимолётный фон в
// начале глушил алёрт о честном зависании в foreground (контрпример
// adversarial-verifier).
//
// AC-17/AC-18 (GlitchTip #2085, 2026-09-29): срок — простой без байтов, а не
// бюджет всей загрузки. Red-proof: без перезапуска на чанке краснеет AC-17.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;

import 'package:liza/pages/chat/events/audio_autoplay_service.dart';
import 'package:liza/utils/network_recovery_trigger.dart';

// Страж реестра регрессии: ledger:RL-audio-prepare-no-dead-window
void main() {
  const deadline = Duration(seconds: 180);
  const justOver = Duration(seconds: 181);

  void goTo(WidgetTester tester, List<AppLifecycleState> path) {
    for (final s in path) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  const toBackground = [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];
  const toForeground = [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ];

  /// Запускает подготовку; [attempts] — по одной фабрике на попытку (повтор
  /// бывает только после `ClientException`). Возвращает геттеры исхода.
  ({Object? Function() error, Object? Function() value, int Function() calls})
  start(
    List<Future<Object?> Function()> attempts, {
    bool suspendable = true,
    void Function(void Function() onBytes)? onAttempt,
  }) {
    Object? error;
    Object? value;
    var calls = 0;
    withForegroundDeadline<Object?>(
      (onBytes) {
        onAttempt?.call(onBytes);
        return attempts[calls++]();
      },
      deadline,
      suspendable: suspendable,
    ).then(
      (v) {
        value = v;
      },
      onError: (Object e) {
        error = e;
      },
    );
    return (error: () => error, value: () => value, calls: () => calls);
  }

  Future<Object?> hang() => Completer<Object?>().future;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/10 — дедлайн, выстреливший во сне '
    'процесса (фон), поднимается как AudioPrepareSuspendedException',
    (tester) async {
      final run = start([hang]);
      goTo(tester, toBackground);
      await tester.pump(justOver);

      expect(run.error(), isA<AudioPrepareSuspendedException>());
      goTo(tester, toForeground);
    },
  );

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/11 — загрузка, пережившая сон, '
    'падает обрывом сразу после возврата: заморозка, не авария',
    (tester) async {
      final second = Completer<Object?>();
      final run = start([
        () => Future.error(ClientException('keep-alive dead')),
        () => second.future,
      ]);
      await tester.pump();
      expect(run.calls(), 2, reason: 'обрыв сокета — ровно один повтор');

      goTo(tester, toBackground);
      await tester.pump(const Duration(seconds: 30));
      goTo(tester, toForeground);
      second.completeError(ClientException('closed by _refreshHttpClients'));
      await tester.pump();

      expect(run.error(), isA<AudioPrepareSuspendedException>());
    },
  );

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/12 — контроль-негатив: в foreground '
    'и при одной лишь шторке (inactive) таймаут остаётся честным сигналом',
    (tester) async {
      final resumedOnly = start([hang]);
      await tester.pump(justOver);
      expect(resumedOnly.error(), isA<TimeoutException>());

      final shadeOnly = start([hang]);
      goTo(tester, const [AppLifecycleState.inactive]);
      await tester.pump(justOver);
      expect(shadeOnly.error(), isA<TimeoutException>());
      goTo(tester, const [AppLifecycleState.resumed]);
    },
  );

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/13 — на desktop свёрнутое окно не '
    'заморозка: таймаут не глушится',
    (tester) async {
      final run = start([hang], suspendable: false);
      goTo(tester, toBackground);
      await tester.pump(justOver);

      expect(run.error(), isA<TimeoutException>());
      goTo(tester, toForeground);
    },
  );

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/14 — мимолётный фон в начале, потом '
    'честное зависание в foreground: полный срок с возврата и АЛЁРТ',
    (tester) async {
      final run = start([hang]);
      await tester.pump(const Duration(seconds: 1));
      goTo(tester, toBackground);
      await tester.pump(const Duration(seconds: 1));
      goTo(tester, toForeground);

      await tester.pump(deadline - const Duration(seconds: 1));
      expect(run.error(), isNull, reason: 'сон не съедает срок');
      await tester.pump(const Duration(seconds: 2));
      expect(run.error(), isA<TimeoutException>());
      expect(run.error(), isNot(isA<AudioPrepareSuspendedException>()));
    },
  );

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/15 — обрыв спустя время после '
    'возврата (вне grace) — честный сбой, не заморозка',
    (tester) async {
      final second = Completer<Object?>();
      final run = start([
        () => Future.error(ClientException('keep-alive dead')),
        () => second.future,
      ]);
      await tester.pump();
      goTo(tester, toBackground);
      await tester.pump(const Duration(seconds: 30));
      goTo(tester, toForeground);
      await tester.pump(const Duration(seconds: 30));
      second.completeError(ClientException('network down'));
      await tester.pump();

      expect(run.error(), isA<ClientException>());
    },
  );

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/16 — не-транспортный сбой (HTTP/декрипт) '
    'в фоне НЕ маскируется под заморозку',
    (tester) async {
      final failure = Completer<Object?>();
      final run = start([() => failure.future]);
      goTo(tester, toBackground);
      failure.completeError(StateError('bad ciphertext'));
      await tester.pump();

      expect(run.error(), isA<StateError>());
      goTo(tester, toForeground);
    },
  );

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/17 — медленная, но живая загрузка '
    'дольше срока доходит: срок считается от последних байтов',
    (tester) async {
      // #2085: 1,12 МБ при ~20 КБ/с — MMR отдал всё за 53 с, клиент рубил на 60-й.
      final body = Completer<Object?>();
      late void Function() onBytes;
      final run = start([() => body.future], onAttempt: (cb) => onBytes = cb);
      for (var i = 0; i < 5; i++) {
        await tester.pump(deadline - const Duration(seconds: 10));
        onBytes();
      }
      body.complete(42);
      await tester.pump();

      expect(run.error(), isNull, reason: 'чанки шли — канал жив');
      expect(run.value(), 42);
    },
  );

  testWidgets(
    'AC:RL-audio-prepare-no-dead-window/18 — байты пошли и встали: полный срок '
    'простоя с последнего чанка и честный таймаут (mobile и desktop)',
    (tester) async {
      for (final suspendable in const [true, false]) {
        late void Function() onBytes;
        final run = start(
          [hang],
          suspendable: suspendable,
          onAttempt: (cb) => onBytes = cb,
        );
        await tester.pump(const Duration(seconds: 50));
        onBytes();
        await tester.pump(deadline - const Duration(seconds: 1));
        expect(run.error(), isNull, reason: 'suspendable=$suspendable');
        await tester.pump(const Duration(seconds: 2));
        expect(run.error(), isA<TimeoutException>());
        expect(run.error(), isNot(isA<AudioPrepareSuspendedException>()));
      }
    },
  );

  testWidgets('успешная загрузка после одного обрыва возвращает результат', (
    tester,
  ) async {
    final run = start([
      () => Future.error(ClientException('keep-alive dead')),
      () async => 42,
    ]);
    await tester.pump();

    expect(run.value(), 42);
    expect(run.error(), isNull);
  });

  test(
    'состояния заморозки: hidden/paused/detached — да, inactive/resumed — нет',
    () {
      expect(isSuspendingLifecycleState(AppLifecycleState.paused), isTrue);
      expect(isSuspendingLifecycleState(AppLifecycleState.hidden), isTrue);
      expect(isSuspendingLifecycleState(AppLifecycleState.detached), isTrue);
      expect(isSuspendingLifecycleState(AppLifecycleState.inactive), isFalse);
      expect(isSuspendingLifecycleState(AppLifecycleState.resumed), isFalse);
      expect(isSuspendingLifecycleState(null), isFalse);
    },
  );
}
