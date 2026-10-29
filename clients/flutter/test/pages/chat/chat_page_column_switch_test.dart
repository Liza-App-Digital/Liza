// ledger:RL-empty-panel-new-request
// ledger:RL-discard-recording-guard
// guard.render:real-widget
//
// Комментарий Александра 28.10: «делаешь экран узким и начинаешь записывать
// голосовое, затем начинаешь расширять экран, и при переключении с одной
// колонки на 2 эпик фейл с потерей записи голосового». Настоящий
// AppRoutes.chatPageBuilder под GoRouter + ShellRoute с TwoColumnLayout, как в
// routes.dart; внутри страницы — настоящий RecordingViewModel.
//
// Red-proof:
//   RP-1: вернуть в chatPageBuilder `defaultPageBuilder` для узкого режима
//     (MaterialPage ↔ ChatRoutePage) → mounts = 3, рекордер утилизирован,
//     AC-23 и запись красные.
//   RP-2: убрать override delegatedTransition в _ChatRoute → на iOS пустая
//     панель под кроссфейдом съезжает, AC-24 красный.
//   RP-3: убрать проверку mounted после WakelockPlus.enable → экран ушёл, пока
//     включался wakelock, и тот остался включённым — красный.

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/recording_view_model.dart';
import 'package:liza/utils/new_request_transition.dart';
import 'package:liza/utils/voice_recording_guard.dart';
import 'package:liza/widgets/layouts/mini_app_host_scope.dart';
import 'package:liza/widgets/layouts/two_column_layout.dart';
import '../../utils/test_client.dart';

class _FakeRecorder implements AudioRecorder {
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  /// Пока не завершён — start «висит», как нативный старт микрофона.
  Completer<void>? pendingStart;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startCalls++;
    await pendingStart?.future;
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    return '/tmp/rec.m4a';
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<Amplitude> getAmplitude() async => Amplitude(current: -30, max: -30);

  @override
  Future<void> dispose() async => disposeCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWakelock extends WakelockPlusPlatformInterface
    with MockPlatformInterfaceMixin {
  bool on = false;

  /// Пока не завершён — включение wakelock «висит».
  Completer<void>? pendingEnable;

  @override
  Future<void> toggle({required bool enable}) async {
    if (enable) await pendingEnable?.future;
    on = enable;
  }

  @override
  Future<bool> get enabled async => on;
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async => '/tmp';
}

const _narrow = Size(600, 900);
const _wide = Size(1400, 900);

void main() {
  late Room room;
  late _FakeWakelock wakelock;
  late int mounts;
  late _FakeRecorder recorder;
  RecordingViewModelState? model;
  final forceColumn = ValueNotifier(false);

  setUpAll(() async {
    PathProviderPlatform.instance = _FakePathProvider();
    room = Room(
      id: '!voice:example.invalid',
      client: await prepareTestClient(loggedIn: true),
    );
  });

  setUp(() {
    wakelock = _FakeWakelock();
    wakelockPlusPlatformInstance = wakelock;
    mounts = 0;
    recorder = _FakeRecorder();
    model = null;
    forceColumn.value = false;
  });

  tearDown(() {
    VoiceRecordingGuard.notifier.value = null;
    NewRequestTransition.reset();
  });

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    Size size = _narrow,
    String initial = '/rooms/!a',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        ShellRoute(
          pageBuilder: (context, state, child) =>
              AppRoutes.noTransitionPageBuilder(
                context,
                state,
                LizaThemes.isColumnMode(context)
                    ? TwoColumnLayout(
                        compactable: true,
                        mainView: const Text('list'),
                        sideView: child,
                      )
                    : child,
              ),
          routes: [
            GoRoute(
              path: '/rooms',
              pageBuilder: (context, state) => AppRoutes.defaultPageBuilder(
                context,
                state,
                const ColoredBox(color: Colors.white, child: Text('panel')),
              ),
              routes: [
                GoRoute(
                  path: ':roomid',
                  pageBuilder: (context, state) => AppRoutes.chatPageBuilder(
                    context,
                    state,
                    _Chat(
                      onMount: () => mounts++,
                      createRecorder: () => recorder,
                      onModel: (m) => model = m,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        builder: (context, child) => ValueListenableBuilder<bool>(
          valueListenable: forceColumn,
          builder: (_, force, _) => MiniAppHostScope(
            forceColumnMode: force,
            compactChatList: false,
            child: child!,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return router;
  }

  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'AC-23: одна ↔ две колонки ∀ {ширина вширь, ширина вузь, панель mini App '
    'вкл/выкл} — ChatPage монтируется один раз',
    (tester) async {
      // AC:RL-empty-panel-new-request/23
      await pumpApp(tester);
      expect(find.text('list'), findsNothing, reason: 'старт в одну колонку');
      expect(mounts, 1);

      await resize(tester, _wide);
      expect(find.text('list'), findsOneWidget, reason: 'две колонки');
      expect(mounts, 1, reason: 'узкое → широкое');

      await resize(tester, _narrow);
      expect(find.text('list'), findsNothing);
      expect(mounts, 1, reason: 'широкое → узкое');

      forceColumn.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('list'), findsOneWidget, reason: 'forceColumnMode');
      expect(mounts, 1, reason: 'панель mini App открылась');

      forceColumn.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(mounts, 1, reason: 'панель mini App закрылась');
      expect(find.text('chat'), findsOneWidget);
    },
  );

  testWidgets(
    'запись голосового переживает смену колонок: тот же State, рекордер не '
    'остановлен и не утилизирован, guard активен, время идёт',
    (tester) async {
      // AC:RL-discard-recording-guard/1
      await pumpApp(tester);
      final before = model!;
      await tester.runAsync(() => before.startRecording(room));
      await tester.pump();
      expect(before.isRecording, isTrue);
      expect(find.text('recording'), findsOneWidget);

      for (final size in [_wide, _narrow, _wide]) {
        final elapsed = before.duration;
        tester.view.physicalSize = size;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)),
        );
        await tester.pump();
        expect(identical(model, before), isTrue, reason: 'State $size');
        expect(before.duration, greaterThan(elapsed), reason: 'таймер $size');
      }

      expect(mounts, 1);
      expect(recorder.startCalls, 1);
      expect(recorder.stopCalls, 0);
      expect(recorder.disposeCalls, 0);
      expect(VoiceRecordingGuard.notifier.value, isNotNull);
      expect(wakelock.on, isTrue);
      expect(find.text('recording'), findsOneWidget);

      before.cancel();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    },
  );

  testWidgets(
    'экран ушёл, пока включался wakelock: wakelock выключен, guard пуст',
    (tester) async {
      // AC:RL-discard-recording-guard/2
      await pumpApp(tester);
      wakelock.pendingEnable = Completer();
      final started = model!.startRecording(room);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpWidget(const SizedBox());
      wakelock.pendingEnable!.complete();
      await tester.runAsync(() async {
        await started;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(wakelock.on, isFalse);
      expect(VoiceRecordingGuard.notifier.value, isNull);
      expect(recorder.startCalls, 0);
    },
  );

  testWidgets(
    'dispose посреди старта записи: guard не залипает, wakelock выключен, '
    'рекордер утилизирован, исключений нет',
    (tester) async {
      // AC:RL-discard-recording-guard/3
      await pumpApp(tester);
      recorder.pendingStart = Completer();
      final started = model!.startRecording(room);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(recorder.startCalls, 1, reason: 'старт висит');

      await tester.pumpWidget(const SizedBox());
      recorder.pendingStart!.complete();
      await tester.runAsync(() async {
        await started;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(VoiceRecordingGuard.notifier.value, isNull);
      expect(wakelock.on, isFalse);
      expect(recorder.disposeCalls, 1);
    },
  );

  testWidgets(
    'AC-24: column-mode — кроссфейд из пустой панели, панель под ним не '
    'смещается',
    (tester) async {
      // AC:RL-empty-panel-new-request/24
      final router = await pumpApp(tester, size: _wide, initial: '/rooms');
      NewRequestTransition.arm('!a');
      router.go('/rooms/!a');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('panel'), findsOneWidget);
      final slides = find.ancestor(
        of: find.text('panel'),
        matching: find.byType(SlideTransition),
      );
      for (final e in slides.evaluate()) {
        final offset = (e.widget as SlideTransition).position.value;
        expect(offset, Offset.zero, reason: 'панель съехала');
      }
      expect(
        tester.getTopLeft(find.text('panel')).dx,
        LizaThemes.columnWidth + LizaThemes.navRailWidth + 1,
      );
      await tester.pump(const Duration(milliseconds: 400));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'AC-25: одна колонка на iOS — как MaterialPage: свайп назад и параллакс '
    'нижнего экрана',
    (tester) async {
      // AC:RL-empty-panel-new-request/25
      final router = await pumpApp(tester, initial: '/rooms');
      router.go('/rooms/!a');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final chatRoute = ModalRoute.of(tester.element(find.text('chat')))!;
      final panelRoute = ModalRoute.of(tester.element(find.text('panel')))!;
      expect(chatRoute, isA<PageRoute>());
      expect(
        panelRoute.secondaryAnimation!.value,
        greaterThan(0),
        reason: 'нижний экран уезжает с параллаксом',
      );
      await tester.pump(const Duration(seconds: 1));
      expect((chatRoute as PageRoute).popGestureEnabled, isTrue);
      expect(chatRoute.transitionDuration, greaterThan(Duration.zero));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('AC-25: открыт в двух колонках, окно сузили — «назад» анимирован '
      'длительностью узкого режима, а не нулём column-mode', (tester) async {
    // AC:RL-empty-panel-new-request/25
    final router = await pumpApp(tester, size: _wide, initial: '/rooms');
    router.go('/rooms/!a');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await resize(tester, _narrow);
    final route =
        ModalRoute.of(tester.element(find.text('chat')))! as PageRoute;
    expect(route.reverseTransitionDuration, greaterThan(Duration.zero));
    router.pop();
    await tester.pump();
    // ignore: invalid_use_of_protected_member
    expect(route.controller!.reverseDuration, route.reverseTransitionDuration);
    await tester.pump(const Duration(milliseconds: 50));
    expect(route.animation!.value, inExclusiveRange(0, 1), reason: 'анимация');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('chat'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}

class _Chat extends StatefulWidget {
  const _Chat({
    required this.onMount,
    required this.createRecorder,
    required this.onModel,
  });

  final VoidCallback onMount;
  final AudioRecorder Function() createRecorder;
  final ValueChanged<RecordingViewModelState> onModel;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: Column(
      children: [
        const Text('chat'),
        RecordingViewModel(
          createRecorder: widget.createRecorder,
          builder: (context, s) {
            widget.onModel(s);
            return Text(s.isRecording ? 'recording' : 'idle');
          },
        ),
      ],
    ),
  );
}
