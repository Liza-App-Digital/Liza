// Локальный macOS harness: flutter main(args), не flutter_test entrypoint.
// Нативные окна/IPC настоящие; сцена тестовая, без WebView, аккаунтов и сети.
// ledger:RL-miniapp-contact ledger:RL-miniapp-start-param-ipc
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_window.dart';

const _native = MethodChannel('liza/miniapp_window');
const _host = WindowMethodChannel(
  'liza/miniapp_host',
  mode: ChannelMode.unidirectional,
);
const _title = 'Liza native QA: campaign_3010';

void record(String event, Object? data) => print(
  'NATIVE_QA ${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'pid': pid, 'event': event, 'data': data})}',
);

/// ObjC обращается только к NSApplication ТЕКУЩЕГО тестового процесса.
/// Нет activate/makeKey/orderFrontRegardless; установленная Лиза недоступна.
class OwnAppKit {
  final library = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
  late final getClass = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Utf8>)
      >('objc_getClass');
  late final getSelector = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Utf8>)
      >('sel_registerName');
  late final send = library
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('objc_msgSend');
  late final sendArgument = library
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Pointer<Void>, IntPtr),
        int Function(Pointer<Void>, Pointer<Void>, int)
      >('objc_msgSend');

  Pointer<Void> selector(String name) {
    final utf8 = name.toNativeUtf8();
    try {
      return getSelector(utf8);
    } finally {
      calloc.free(utf8);
    }
  }

  Pointer<Void> get application {
    final name = 'NSApplication'.toNativeUtf8();
    try {
      return Pointer.fromAddress(
        send(getClass(name), selector('sharedApplication')),
      );
    } finally {
      calloc.free(name);
    }
  }

  Pointer<Void> object(Pointer<Void> target, String method) =>
      Pointer.fromAddress(send(target, selector(method)));

  List<Pointer<Void>> get windows {
    final array = object(application, 'windows');
    return [
      for (var index = 0; index < send(array, selector('count')); index++)
        Pointer.fromAddress(
          sendArgument(array, selector('objectAtIndex:'), index),
        ),
    ];
  }

  Pointer<Void> get ownMiniWindow => windows.singleWhere((window) {
    final title = object(window, 'title');
    final text = object(title, 'UTF8String').cast<Utf8>().toDartString();
    return text == _title;
  });

  void act(String method) => sendArgument(ownMiniWindow, selector(method), 0);

  int get windowNumber => send(ownMiniWindow, selector('windowNumber'));

  void prohibitActivation() {
    // NSApplicationActivationPolicyProhibited — свой процесс не крадёт фокус.
    sendArgument(application, selector('setActivationPolicy:'), 2);
    for (final window in windows) {
      sendArgument(window, selector('orderOut:'), 0);
    }
  }
}

Future<void> child(List<String> args) async {
  final config = MiniAppWindowConfig.fromJson(
    Map<String, Object?>.from(jsonDecode(args[2]) as Map),
  );
  final controller = await WindowController.fromCurrentEngine();
  final remote = RemoteMiniAppHostApi.fromConfig(config);
  final appKit = OwnAppKit();
  _native.setMethodCallHandler((call) async {
    if (call.method == 'visibilityChanged') {
      record('native_callback', call.arguments);
      await remote.reportVisibility(
        Map<Object?, Object?>.from(call.arguments as Map),
      );
    }
  });
  await _native.invokeMethod<void>('setTitle', {'title': _title});
  await controller.setWindowMethodHandler((call) async {
    if (call.method == 'probe') {
      return {
        'window_id': controller.windowId,
        'window_number': appKit.windowNumber,
        'app_active':
            (appKit.send(appKit.application, appKit.selector('isActive')) &
                255) !=
            0,
        'window_visible':
            (appKit.send(appKit.ownMiniWindow, appKit.selector('isVisible')) &
                255) !=
            0,
        'window_minimized':
            (appKit.send(
                  appKit.ownMiniWindow,
                  appKit.selector('isMiniaturized'),
                ) &
                255) !=
            0,
        'config': config.toJson(),
        'snapshot': await _native.invokeMapMethod<Object?, Object?>(
          'visibility',
        ),
      };
    }
    if (call.method == 'act') {
      final method = call.arguments as String;
      if (!{
        'orderFront:',
        'miniaturize:',
        'deminiaturize:',
        'orderOut:',
      }.contains(method)) {
        throw ArgumentError('Действие не разрешено в harness');
      }
      final started = DateTime.now().toUtc().toIso8601String();
      appKit.act(method);
      record('action', {
        'method': method,
        'started_at': started,
        'completed': true,
      });
      return null;
    }
    if (call.method == 'close') {
      Timer.run(() => _native.invokeMethod<void>('close'));
      return null;
    }
    throw MissingPluginException(call.method);
  });
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text(_title))),
    ),
  );
  record('child_ready', {
    'window_id': controller.windowId,
    'start_param': config.startParam,
  });
}

Future<void> parent() async {
  OwnAppKit().prohibitActivation();
  record('parent_ready', {
    'activation_policy': 'prohibited',
    'network': 'none',
  });
  runApp(const MaterialApp(home: SizedBox()));
  final manager = MiniAppManager.instance;
  final client = Client(
    'Liza native QA — без входа',
    database: await MatrixSdkDatabase.init(
      'native-qa-memory',
      database: await databaseFactoryFfi.openDatabase(':memory:'),
      sqfliteFactory: databaseFactoryFfi,
    ),
  );
  manager.windowsSupported = true;
  manager.open(
    appId: 'native-qa-3010',
    appUrl: 'https://example.invalid/',
    appName: _title,
    room: Room(id: '!native-qa:example.invalid', client: client),
    startParam: 'campaign_3010',
    botMxid: '@native-qa:example.invalid',
  );
  final instance = manager.detachedApps.single;
  var callbackCount = 0;
  await _host.setMethodCallHandler((call) async {
    callbackCount++;
    await MiniAppWindows.instance.debugHandleHostCall(call);
    record('parent_ipc', {
      'method': call.method,
      'callback_count': callbackCount,
      'visible': instance.interactiveState.visible,
      'epoch': instance.interactiveState.visibilityEpoch,
      'args': call.arguments,
    });
    return null;
  });
  final config = MiniAppWindowConfig.of(instance, null);
  final controller = await WindowController.create(
    WindowConfiguration(
      arguments: jsonEncode(config.toJson()),
      hiddenAtLaunch: true,
    ),
  );
  Future<Map> probe() async => (await controller
      .invokeMethod<Map>('probe')
      .timeout(const Duration(seconds: 3)))!;
  Map? initial;
  for (var attempt = 0; attempt < 40 && initial == null; attempt++) {
    try {
      initial = await probe();
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  if (initial == null) {
    throw StateError('Второй engine не ответил за bounded retry');
  }
  if ((initial['config'] as Map)['start_param'] != 'campaign_3010' ||
      initial['window_id'] != controller.windowId) {
    throw StateError('Неверный config или engine в IPC');
  }
  record('created', initial);
  await Future<void>.delayed(const Duration(seconds: 8));
  final steps = Platform.environment['LIZA_QA_HIDE_ONLY'] == '1'
      ? [('shown', 'orderFront:'), ('hidden', 'orderOut:')]
      : [
          ('shown', 'orderFront:'),
          ('minimized', 'miniaturize:'),
          ('restored', 'deminiaturize:'),
          ('hidden', 'orderOut:'),
        ];
  for (final step in steps) {
    final before = await probe();
    final beforeCallbacks = callbackCount;
    await controller.invokeMethod<void>('act', step.$2);
    await Future<void>.delayed(const Duration(seconds: 2));
    final after = await probe();
    record(step.$1, {
      'before': before,
      'after': after,
      'callbacks_during_action': callbackCount - beforeCallbacks,
    });
    await Future<void>.delayed(const Duration(seconds: 10));
  }
  record('before_close', await probe());
  await controller.invokeMethod<void>('close');
  await Future<void>.delayed(const Duration(seconds: 2));
  final alive = (await WindowController.getAll()).any(
    (w) => w.windowId == controller.windowId,
  );
  record('closed', {
    'window_still_registered': alive,
    'callback_count': callbackCount,
  });
  if (alive) throw StateError('Закрытое окно осталось в native registry');
  record('limitations', {
    'pending_request_cancel': 'NOT_RUN: нет authenticated/foreground consent',
    'direct_focus':
        'NOT_RUN: activation запрещена у собственного тестового процесса',
  });
  manager.closeAll();
  await _host.setMethodCallHandler(null);
  await client.dispose();
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.isNotEmpty && args.first == kMiniAppWindowEntryArg) {
    await child(args);
    return;
  }
  try {
    await parent().timeout(const Duration(seconds: 130));
    record('finished', {'status': 'native_observation_complete'});
    exit(0);
  } catch (error, stack) {
    record('failed', {'error': '$error', 'stack': '$stack'});
    exit(1); // Завершает только собственный процесс вместе с его вторым engine.
  }
}
