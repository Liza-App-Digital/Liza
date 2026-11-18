// ledger:RL-miniapp-detached-window
import 'dart:async';
import 'dart:convert';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
import '../../utils/test_client.dart';

void main() {
  const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
  const desktop = MethodChannel('mixin.one/desktop_multi_window');
  const native = MethodChannel('liza/miniapp_window');
  final manager = MiniAppManager.instance;
  testWidgets(
    'AC62 left resize indicator centered without pointer interception',
    (tester) async {
      // AC:RL-miniapp-detached-window/62
      final harness = _GeometryWindowHarness(tester);
      addTearDown(harness.dispose);
      await harness.mount(_geometryConfig());
      final grip = find.byKey(
        const ValueKey('miniapp-window-resize-indicator'),
      );
      expect(grip, findsOneWidget);
      final rect = tester.getRect(grip);
      expect(rect.size, const Size(4, 40));
      expect(rect.left, 0);
      expect(
        rect.center.dy,
        tester.view.physicalSize.height / tester.view.devicePixelRatio / 2,
      );
      final ignored = find.ancestor(
        of: grip,
        matching: find.byType(IgnorePointer),
      );
      expect(tester.widget<IgnorePointer>(ignored.first).ignoring, isTrue);
    },
  );
  for (final account in ['@alice:example.invalid', '', null]) {
    for (final kind in [MiniAppKind.miniApp, MiniAppKind.html]) {
      testWidgets('geometry present: $account/${kind.name}', (tester) async {
        final harness = _GeometryWindowHarness(tester);
        addTearDown(harness.dispose);
        await harness.mount(_geometryConfig(account: account, kind: kind));
        final present = harness.calls.singleWhere((c) => c.method == 'present');
        // AC:RL-miniapp-detached-window/56 — native получает реальный account
        // и kind, включая отсутствие аккаунта и HTML без mini App preference.
        expect(present.arguments, containsPair('accountUserId', account));
        expect(present.arguments, containsPair('kind', kind.name));
        expect(
          (present.arguments as Map)['geometryGeneration'],
          isA<int>().having(
            (value) => value,
            'generation',
            greaterThanOrEqualTo(0),
          ),
        );
        expect(present.arguments, containsPair('title', 'Первое'));
      });
    }
  }

  testWidgets('geometry navigate atomically replaces context', (tester) async {
    final harness = _GeometryWindowHarness(tester);
    addTearDown(harness.dispose);
    await harness.mount(_geometryConfig());
    final generation =
        (harness.calls.singleWhere((c) => c.method == 'present').arguments
                as Map)['geometryGeneration']
            as int;
    final replacements = [
      _geometryConfig(account: '@bob:example.invalid', content: '2'),
      _geometryConfig(
        account: '@bob:example.invalid',
        kind: MiniAppKind.html,
        content: '3',
      ),
      _geometryConfig(account: null, kind: MiniAppKind.html, content: '4'),
    ];
    for (final (index, config) in replacements.indexed) {
      harness.calls.clear();
      await harness.navigate(config);
      // AC:RL-miniapp-detached-window/56 — даже при том же appId меняются
      // account/kind; новый контекст установлен до следующего focus/event.
      expect(harness.calls.map((c) => c.method), ['setTitle', 'focus']);
      expect(harness.calls.first.arguments, {
        'title': config.appName,
        'accountUserId': config.accountUserId,
        'kind': config.kind.name,
        'geometryGeneration': generation + index + 1,
      });
    }
  });

  testWidgets('geometry same-account deep-link never presents twice', (
    tester,
  ) async {
    final harness = _GeometryWindowHarness(tester);
    addTearDown(harness.dispose);
    await harness.mount(_geometryConfig());
    final generation =
        (harness.calls.singleWhere((c) => c.method == 'present').arguments
                as Map)['geometryGeneration']
            as int;
    await harness.navigate(_geometryConfig(content: 'next'));
    // AC:RL-miniapp-detached-window/57 — deep-link меняет поколение контекста,
    // но не вызывает повторный present с восстановлением/подгонкой размера.
    expect(harness.calls.where((c) => c.method == 'present'), hasLength(1));
    expect(harness.calls.singleWhere((c) => c.method == 'setTitle').arguments, {
      'title': 'Следующее next',
      'accountUserId': '@alice:example.invalid',
      'kind': 'miniApp',
      'geometryGeneration': generation + 1,
    });
  });

  testWidgets('geometry pending navigate presents current identity', (
    tester,
  ) async {
    final harness = _GeometryWindowHarness(tester, holdReady: true);
    addTearDown(harness.dispose);
    await harness.mount(_geometryConfig());
    await harness.navigate(
      _geometryConfig(
        account: '@bob:example.invalid',
        kind: MiniAppKind.html,
        content: 'new-owner',
      ),
    );
    // AC:RL-miniapp-detached-window/57 — до ready нет видимого окна/focus.
    expect(harness.calls.map((c) => c.method), ['setTitle']);
    final pendingContext = Map<Object?, Object?>.from(
      harness.calls.single.arguments as Map,
    );
    harness.ready.complete(true);
    await tester.pump();
    await tester.pump();
    final present = harness.calls.singleWhere((c) => c.method == 'present');
    // AC:RL-miniapp-detached-window/56 — initial widget.config уже устарел:
    // первое present обязано взять account/kind/generation последнего navigate.
    expect(
      present.arguments,
      containsPair('accountUserId', '@bob:example.invalid'),
    );
    expect(present.arguments, containsPair('kind', 'html'));
    expect(present.arguments, containsPair('title', 'Следующее new-owner'));
    expect(
      present.arguments,
      containsPair('geometryGeneration', pendingContext['geometryGeneration']),
    );
    expect(harness.calls.where((c) => c.method == 'present'), hasLength(1));
  });

  for (final scenario in [
    'close',
    'attach',
    'reopen',
    'live',
    'navigate',
    'host-error',
    'host-timeout',
    'registration-error',
    'registration-timeout',
    'close-after-ready',
    'navigate-held-ready',
    'dispose-before-registration',
    'host-error-native-close-error',
    'close-after-ready-native-close-error',
  ]) {
    testWidgets('AC26 lifecycle child: $scenario', (tester) async {
      final id = 'early-$scenario';
      final registration = Completer<void>();
      final readyReply = Completer<void>();
      var readyRequests = 0;
      final nativeCalls = <String>[];
      late MiniAppWindowConfig config;
      MiniAppWindowConfig? initialConfig;
      var registered = false;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(desktop, (call) async {
        if (call.method == 'createWindow') {
          config = MiniAppWindowConfig.fromJson(
            Map<String, Object?>.from(
              jsonDecode((call.arguments as Map)['arguments'] as String) as Map,
            ),
          );
          initialConfig ??= config;
          return id;
        }
        if (call.method == 'getWindowDefinition') {
          return {'windowId': id, 'windowArgument': ''};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'registerMethodHandler') {
          if (args['channel'] == 'mixin.one/window_controller/$id') {
            await registration.future;
            if (scenario == 'registration-error') {
              throw PlatformException(code: 'CHANNEL_LIMIT_REACHED');
            }
            if (scenario == 'registration-timeout') {
              await Completer<void>().future;
            }
            registered = true;
          }
          return null;
        }
        if (args['channel'] == 'liza/miniapp_host') {
          if (args['method'] == 'fetchPageDocument') {
            throw StateError('Документ не нужен lifecycle-стражу');
          }
          if (args['method'] == 'windowReady') {
            readyRequests++;
            if (scenario.startsWith('host-error')) {
              throw PlatformException(code: 'CHANNEL_UNREGISTERED');
            }
            if (scenario == 'host-timeout') return Completer<Object?>().future;
            final result = await MiniAppWindows.instance.debugHandleHostCall(
              MethodCall('windowReady', args['arguments']),
            );
            if (scenario.startsWith('close-after-ready')) manager.close(id);
            if (scenario == 'navigate-held-ready') await readyReply.future;
            return result;
          }
          return MiniAppWindows.instance.debugHandleHostCall(
            MethodCall(args['method'] as String, args['arguments']),
          );
        }
        if (!registered) throw PlatformException(code: 'CHANNEL_UNREGISTERED');
        final response = Completer<Object?>();
        messenger.handlePlatformMessage(
          channels.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('methodCall', args),
          ),
          (data) {
            try {
              response.complete(
                const StandardMethodCodec().decodeEnvelope(data!),
              );
            } catch (e, st) {
              response.completeError(e, st);
            }
          },
        );
        return response.future;
      });
      messenger.setMockMethodCallHandler(native, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'close' && scenario.endsWith('native-close-error')) {
          throw PlatformException(code: 'NATIVE_CLOSE_FAILED');
        }
        return null;
      });
      manager.windowsSupported = true;
      MiniAppWindows.instance.start();
      late Client client;
      await tester.runAsync(() async {
        client = await prepareTestClient();
      });
      manager.open(
        appUrl: 'https://fixture.invalid/',
        appId: id,
        appName: 'Early',
        room: Room(id: '!fixture:invalid', client: client),
        kind: MiniAppKind.html,
      );
      if (scenario == 'close' || scenario == 'reopen') manager.close(id);
      if (scenario == 'attach') manager.attach(id);
      if (scenario == 'reopen' || scenario.startsWith('navigate')) {
        manager.open(
          appUrl: 'https://fixture.invalid/',
          appId: id,
          appName: 'New',
          room: Room(id: '!fixture:invalid', client: client),
          kind: MiniAppKind.html,
          startParam: 'new',
        );
      }
      await tester.pumpWidget(
        MiniAppWindowApp(
          controller: WindowController.fromWindowId(id),
          config: initialConfig!,
        ),
      );
      // AC:RL-miniapp-detached-window/26 — отменённое скрытое окно не present.
      expect(nativeCalls, isNot(contains('present')));
      if (scenario == 'dispose-before-registration') {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      registration.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      if (scenario == 'navigate-held-ready') {
        // Direct focus тоже не должен обойти удержанный ready-ответ.
        manager.open(
          appUrl: 'https://fixture.invalid/',
          appId: id,
          appName: 'New',
          room: Room(id: '!fixture:invalid', client: client),
          kind: MiniAppKind.html,
          startParam: 'new',
        );
        await tester.pump();
        expect(nativeCalls, contains('setTitle'));
        expect(nativeCalls, isNot(contains('focus')));
        expect(nativeCalls, isNot(contains('present')));
        readyReply.complete();
        await tester.pump();
      }
      if (scenario.endsWith('timeout')) {
        await tester.pump(const Duration(seconds: 21));
      }
      if (scenario == 'dispose-before-registration') {
        expect(readyRequests, 0);
        expect(nativeCalls, isNot(contains('present')));
      } else if (scenario == 'live' || scenario.startsWith('navigate')) {
        expect(nativeCalls, contains('present'));
        if (scenario == 'navigate') expect(nativeCalls, contains('setTitle'));
      } else {
        expect(nativeCalls, contains('close'));
        expect(nativeCalls, isNot(contains('present')));
      }
      if (scenario == 'reopen') {
        expect(manager.detachedApps.single.startParam, 'new');
      }
      if (scenario == 'close' || scenario == 'close-after-ready') {
        expect(manager.detachedApps, isEmpty);
      }
      manager.closeAll();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      messenger.setMockMethodCallHandler(channels, null);
      messenger.setMockMethodCallHandler(desktop, null);
      messenger.setMockMethodCallHandler(native, null);
      manager.windowsSupported = false;
      await tester.runAsync(client.dispose);
    });
  }
}

MiniAppWindowConfig _geometryConfig({
  String? account = '@alice:example.invalid',
  MiniAppKind kind = MiniAppKind.miniApp,
  String content = '1',
}) => MiniAppWindowConfig(
  appId: 'shared-app-id',
  appUrl: 'https://fixture.invalid/',
  appName: content == '1' ? 'Первое' : 'Следующее $content',
  appType: 'first_party',
  appStartPath: '/',
  accountUserId: account,
  roomId: '!fixture:invalid',
  contentKey: 'shared-app-id#$content',
  dark: false,
  seedColor: Colors.indigo.toARGB32(),
  kind: kind,
);

/// Реальный child и его зарегистрированный IPC-handler. Содержимое оставлено
/// в штатном error-state: для стража контекста native WebView не требуется.
class _GeometryWindowHarness {
  static const _channels = MethodChannel(
    'mixin.one/desktop_multi_window/channels',
  );
  static const _native = MethodChannel('liza/miniapp_window');
  static const _id = 'geometry-child';
  final WidgetTester tester;
  final calls = <MethodCall>[];
  final ready = Completer<bool>();

  _GeometryWindowHarness(this.tester, {bool holdReady = false}) {
    if (!holdReady) ready.complete(true);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channels, (call) async {
      if (call.method != 'invokeMethod') return null;
      final args = call.arguments as Map;
      if (args['method'] == 'windowReady') return ready.future;
      if (args['method'] == 'fetchInitData' ||
          args['method'] == 'fetchPageDocument') {
        throw PlatformException(code: 'DOCUMENT_NOT_NEEDED');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_native, (call) async {
      if (call.method == 'visibility') return <String, Object?>{};
      calls.add(call);
      return null;
    });
  }

  Future<void> mount(MiniAppWindowConfig config) async {
    await tester.pumpWidget(
      MiniAppWindowApp(
        controller: WindowController.fromWindowId(_id),
        config: config,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(MiniAppWindowHeader), findsOneWidget);
  }

  Future<void> navigate(MiniAppWindowConfig config) async {
    final response = Completer<Object?>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channels.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('methodCall', {
          'channel': 'mixin.one/window_controller/$_id',
          'method': 'navigate',
          'arguments': config.toJson(),
        }),
      ),
      (data) {
        try {
          response.complete(const StandardMethodCodec().decodeEnvelope(data!));
        } catch (e, st) {
          response.completeError(e, st);
        }
      },
    );
    await tester.pump();
    await response.future;
    await tester.pump();
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channels,
      null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _native,
      null,
    );
  }
}
