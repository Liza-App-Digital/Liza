// ledger:RL-force-update-staged-policy
//
// Слой обязательного обновления на РЕАЛЬНОМ виджете UpdateGate. Подменены
// только контроллер (свои prefs) и признак звонка — сам слой, экраны, кнопки
// и опрос «занят» прод-кода.
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/utils/voice_recording_guard.dart';
import 'package:liza/widgets/update_gate.dart';
import 'package:liza/widgets/update_read_only_bar.dart';

import '../utils/test_client.dart';

UpdatePolicy _policy(UpdateStage stage, {Duration later = Duration.zero}) =>
    UpdatePolicy(
      stage: stage,
      latestBuild: 3780,
      updateUrl: 'https://apk.test/liza.apk',
      deadlineAt: DateTime.utc(2026, 11, 8, 12),
      serverNow: DateTime.utc(2026, 11, 2, 12).add(later),
    );

void main() {
  late UpdatePolicyController controller;
  var inCall = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    controller = UpdatePolicyController(await SharedPreferences.getInstance());
    UpdatePolicyController.current.value = UpdatePolicy.none;
    VoiceRecordingGuard.notifier.value = null;
    inCall = false;
  });

  tearDown(() {
    UpdatePolicyController.current.value = UpdatePolicy.none;
    VoiceRecordingGuard.notifier.value = null;
  });

  Future<void> pumpApp(WidgetTester tester, {Widget? body}) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: UpdateGate(
          controller: controller,
          hasActiveCall: () => inCall,
          child: Scaffold(body: body ?? const TextField(key: Key('composer'))),
        ),
      ),
    );
    // Делегат L10n грузится асинхронно — до него дерево пустое.
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer')), findsOneWidget);
  }

  Future<void> setStage(
    WidgetTester tester,
    UpdateStage stage, {
    Duration later = Duration.zero,
  }) async {
    await controller.applyFetched(_policy(stage, later: later), 3771);
    await tester.pump();
  }

  final hard = find.byKey(const Key('update_gate_hard'));
  final soft = find.byKey(const Key('update_gate_soft'));

  // AC:RL-force-update-staged-policy/13
  testWidgets('этапы без экрана: none / recommended / announce', (
    tester,
  ) async {
    await pumpApp(tester);
    for (final stage in [
      UpdateStage.none,
      UpdateStage.recommended,
      UpdateStage.announce,
    ]) {
      await setStage(tester, stage);
      expect(hard, findsNothing, reason: stage.name);
      expect(soft, findsNothing, reason: stage.name);
    }
  });

  // AC:RL-force-update-staged-policy/11
  testWidgets('жёсткий: экран без «Позже», «Посмотреть чаты» → чаты живы', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'черновик');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await setStage(tester, UpdateStage.hard);
    expect(hard, findsOneWidget);
    expect(find.byKey(const Key('update_gate_later')), findsNothing);
    expect(find.text('Нужно обновить приложение'), findsOneWidget);
    expect(find.textContaining('черновики сохранятся'), findsOneWidget);

    await tester.tap(find.byKey(const Key('update_gate_view_chats')));
    await tester.pump();
    expect(hard, findsNothing);
    // Дерево под слоем не пересоздавалось — набранный текст на месте.
    expect(find.text('черновик'), findsOneWidget);

    // Повторный ответ сервера в том же запуске экран не возвращает.
    await setStage(tester, UpdateStage.hard);
    expect(hard, findsNothing);
  });

  // AC:RL-force-update-staged-policy/9
  testWidgets('мягкий: дата, «Позже (осталось 3)», после «Позже» — счётчик 2', (
    tester,
  ) async {
    await pumpApp(tester);
    await setStage(tester, UpdateStage.soft);
    expect(soft, findsOneWidget);
    expect(find.text('Обновите приложение до 8 ноября'), findsOneWidget);
    expect(find.text('Позже (осталось 3)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('update_gate_later')));
    // «Позже» сначала сохраняет счётчик, потом закрывает экран.
    await tester.pumpAndSettle();
    expect(soft, findsNothing);
    expect(controller.postponesLeft, 2);
    // Через час (серверное время идёт вперёд) интервал 24 ч не прошёл —
    // повторный ответ экран не поднимает.
    await setStage(tester, UpdateStage.soft, later: const Duration(hours: 1));
    expect(soft, findsNothing);
  });

  testWidgets('мягкий экран не показывается, когда «Позже» исчерпано', (
    tester,
  ) async {
    await pumpApp(tester);
    // Кэш и три «Позже» — до ответа сервера, как после трёх запусков.
    await controller.applyFetched(_policy(UpdateStage.soft), 3771);
    UpdatePolicyController.current.value = UpdatePolicy.none;
    for (var i = 0; i < 3; i++) {
      await controller.postpone();
    }
    UpdatePolicyController.current.value = _policy(UpdateStage.soft);
    await tester.pump();
    expect(soft, findsNothing);
  });

  // AC:RL-force-update-staged-policy/13
  testWidgets('звонок: экран ждёт конца разговора', (tester) async {
    inCall = true;
    await pumpApp(tester);
    await setStage(tester, UpdateStage.hard);
    expect(hard, findsNothing);
    inCall = false;
    await tester.pump(const Duration(seconds: 3));
    expect(hard, findsOneWidget);
    // Новый звонок поверх уже открытого экрана — экран уходит.
    inCall = true;
    await tester.pump(const Duration(seconds: 3));
    expect(hard, findsNothing);
  });

  testWidgets('запись голосового: экран ждёт её окончания', (tester) async {
    final recording = ActiveVoiceRecording(
      durationOf: () => const Duration(seconds: 5),
      cancel: () {},
    );
    VoiceRecordingGuard.register(recording);
    await pumpApp(tester);
    await setStage(tester, UpdateStage.hard);
    expect(hard, findsNothing);
    VoiceRecordingGuard.unregister(recording);
    await tester.pump(const Duration(seconds: 3));
    expect(hard, findsOneWidget);
  });

  testWidgets('набор текста: экран ждёт, пока поле не опустеет', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'пишу…');
    await setStage(tester, UpdateStage.soft);
    expect(soft, findsNothing);
    await tester.enterText(find.byKey(const Key('composer')), '');
    await tester.pump(const Duration(seconds: 3));
    expect(soft, findsOneWidget);
  });

  group('режим чтения', () {
    late Client client;
    setUpAll(() async => client = await prepareTestClient());
    Room room(Membership membership) =>
        Room(id: '!r:test', client: client, membership: membership);

    // AC:RL-force-update-staged-policy/10
    test(
      'плашка вместо поля ввода — только в hard и только участнику',
      () async {
        for (final stage in UpdateStage.values) {
          await controller.applyFetched(_policy(stage), 3771);
          expect(
            showUpdateReadOnlyBar(room(Membership.join)),
            stage == UpdateStage.hard,
            reason: stage.name,
          );
        }
        expect(showUpdateReadOnlyBar(room(Membership.leave)), isFalse);
        expect(showUpdateReadOnlyBar(room(Membership.invite)), isFalse);
      },
    );

    test('read_only_enabled=false — отправка не блокируется', () async {
      await controller.applyFetched(
        UpdatePolicy(stage: UpdateStage.hard, readOnlyEnabled: false),
        3771,
      );
      expect(UpdatePolicyController.readOnly, isFalse);
    });

    testWidgets('действие отбивается подсказкой с кнопкой «Обновить»', (
      tester,
    ) async {
      final results = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  const UpdateReadOnlyBar(),
                  TextButton(
                    key: const Key('act'),
                    onPressed: () =>
                        results.add(blockedByUpdateReadOnly(context)),
                    child: const Text('отправить'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('act')));
      await tester.pump();
      expect(results, [false]);
      expect(find.byKey(const Key('update_read_only_snackbar')), findsNothing);

      await controller.applyFetched(_policy(UpdateStage.hard), 3771);
      await tester.tap(find.byKey(const Key('act')));
      await tester.pump();
      expect(results, [false, true]);
      expect(
        find.byKey(const Key('update_read_only_snackbar')),
        findsOneWidget,
      );
      expect(
        find.text(
          'В этой версии отправка недоступна. Обновите приложение, чтобы отвечать.',
        ),
        findsOneWidget,
      );
      expect(find.text('Обновите приложение, чтобы отвечать'), findsOneWidget);
    });
  });
}
