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
