// ignore_for_file: depend_on_referenced_packages
// ledger:RL-miniapp-contact ledger:RL-miniapp-start-param-ipc
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_contact.dart';
import 'package:liza/pages/chat/mini_app_host_api.dart';
import 'package:liza/pages/chat/mini_app_interactive.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import '../../utils/test_client.dart';

const appUrl = 'https://shop.example.invalid/';
const botMxid = '@shop:example.invalid';
const doc = '0123456789abcdef0123456789abcdef0123456789abcdef';

class PhoneApi extends FakeMatrixApi {
  List<Map<String, dynamic>> phones = [];
  @override
  FutureOr<http.Response> mockIntercept(http.Request request) {
    if (request.url.path.endsWith('/account/3pid')) {
      return http.Response(
        jsonEncode({
          'threepids': [
            for (final phone in phones)
              {'added_at': 1, 'validated_at': 1, ...phone},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return super.mockIntercept(request);
  }
}

void main() {
  final manager = MiniAppManager.instance;
  late Client client;
  late Room room;
  late PhoneApi phones;
  late List<http.Request> requests;
  var registered = true;
  var queryCount = 0;

  http.Response response(Object data) => http.Response(
    jsonEncode(data),
    200,
    headers: {'content-type': 'application/json'},
  );

  Future<void> setup(WidgetTester tester) async {
    phones = PhoneApi();
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true, httpClient: phones);
    });
    room = Room(id: '!shop:example.invalid', client: client);
    requests = [];
    registered = true;
    queryCount = 0;
    BotInteractiveApi.transportFactory = () => MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/descriptor')) {
        return response({
          'registered': registered,
          'mxid': botMxid,
          'miniapps': [
            {'app_id': 'shop', 'url': appUrl, 'name': 'Магазин'},
          ],
        });
      }
      if (request.url.path.endsWith('/query')) {
        queryCount++;
        return response({
          'query_id': 'query_0123456789abcdef',
          'status': 'pending',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
        });
      }
      return response({'status': 'pending', 'cancelled': true});
    });
    RoomMiniAppHostApi.transportFactory = () => MockClient((request) async {
      requests.add(request);
      return response({
        'init_data': 'app_id=shop&hash=fake&query_id=query_0123456789abcdef',
        'verified_app_url': appUrl,
      });
    });
    addTearDown(() async {
      manager.closeAll();
      manager.windowsSupported = false;
      BotInteractiveApi.transportFactory = http.Client.new;
      RoomMiniAppHostApi.transportFactory = http.Client.new;
      await client.dispose();
    });
  }

  RoomMiniAppHostApi host({
    MiniAppInteractiveState? state,
    String start = '',
    String? join,
  }) => RoomMiniAppHostApi(
    room: room,
    appId: 'shop',
    appUrl: appUrl,
    botMxid: botMxid,
    startParam: start,
    joinRequestQueryId: join,
    interactiveSessionId: doc,
    interactiveState: state,
  );

  testWidgets(
    'реальный host: start/query подписываются, state переживает rebuild',
    (tester) async {
      // AC:RL-miniapp-start-param-ipc/1
      await setup(tester);
      final state = MiniAppInteractiveState();
      await host(state: state, start: 'campaign_7').fetchInitData();
      await host(state: state, start: 'campaign_7').fetchInitData();
      expect(queryCount, 1);
      final init = requests
          .where((r) => r.url.path.endsWith('/init_data'))
          .last;
      expect(jsonDecode(init.body), {
        'app_id': 'shop',
        'app_url': appUrl,
        'room_id': room.id,
        'start_param': 'campaign_7',
        'query_id': 'query_0123456789abcdef',
      });
      expect(init.followRedirects, isFalse);
      await host(join: 'join_0123456789abcdef').fetchInitData();
      final join = jsonDecode(requests.last.body) as Map;
      expect(join['chat_join_request_query_id'], 'join_0123456789abcdef');
      expect(join.containsKey('query_id'), isFalse);
      expect(queryCount, 1);
    },
  );

  testWidgets(
    'manager очищает startParam, сохраняет appStartPath и меняет generation',
    (tester) async {
      // AC:RL-miniapp-start-param-ipc/2
      await setup(tester);
      manager.open(
        appUrl: appUrl,
        appId: 'shop',
        appName: 'Магазин',
        room: room,
        appStartPath: '#!/product/7',
        startParam: 'campaign',
        botMxid: botMxid,
      );
      final first = manager.activeApp!;
      manager.open(
        appUrl: appUrl,
        appId: 'shop',
        appName: 'Магазин',
        room: room,
        botMxid: botMxid,
      );
      final cleared = manager.activeApp!;
      expect(cleared.startParam, '');
      expect(cleared.appStartPath, '#!/product/7');
      expect(cleared.generation, first.generation + 1);
      expect(first.interactiveState.active, isFalse);
      manager.detach('shop');
      final config = MiniAppWindowConfig.of(manager.detachedApps.single, null);
      final back = MiniAppWindowConfig.fromJson(
        Map<String, Object?>.from(
          jsonDecode(jsonEncode(config.toJson())) as Map,
        ),
      );
      expect(back.toJson(), config.toJson());
      expect(back.botMxid, botMxid);
      expect(back.interactiveSessionId, isNot(first.interactiveSessionId));
    },
  );

  testWidgets(
    'настоящий desktop RPC отвергает старый content/session/account',
    (tester) async {
      // AC:RL-miniapp-start-param-ipc/3
      await setup(tester);
      manager.windowsSupported = true;
      manager.open(
        appUrl: appUrl,
        appId: 'shop',
        appName: 'Магазин',
        room: room,
        botMxid: botMxid,
        startParam: 'desktop',
      );
      final config = MiniAppWindowConfig.of(manager.detachedApps.single, null);
      const channel = MethodChannel('mixin.one/desktop_multi_window/channels');
      final sent = <Map>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final args = call.arguments as Map;
        sent.add(args);
        return MiniAppWindows.instance.debugHandleHostCall(
          MethodCall(args['method'] as String, args['arguments']),
        );
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final remote = RemoteMiniAppHostApi.fromConfig(config);
      expect(await remote.fetchInitData(), contains('hash='));
      final rpc = sent.single['arguments'] as Map;
      expect(rpc['content_key'], config.contentKey);
      expect(rpc['session_id'], config.interactiveSessionId);
      expect(rpc['account_user_id'], client.userID);
      manager.open(
        appUrl: appUrl,
        appId: 'shop',
        appName: 'Магазин',
        room: room,
        botMxid: botMxid,
        startParam: 'changed',
      );
      await expectLater(remote.fetchInitData(), throwsA(isA<Exception>()));
    },
  );

  testWidgets(
    'contact: реальный host/consent, до выбора нет результата; email не телефон',
    (tester) async {
      // AC:RL-miniapp-contact/1 AC:RL-miniapp-contact/2
      await setup(tester);
      phones.phones = [
        {'medium': 'email', 'address': 'private@example.invalid'},
        {'medium': 'msisdn', 'address': '+79990000001'},
        {'medium': 'msisdn', 'address': '+79990000002'},
      ];
      final api = host();
      await api.fetchInitData();
      await api.interactiveRequest('activateDocument', {'document_id': doc});
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await requestMiniAppContact(
                    context: context,
                    host: api,
                    recipient: 'Магазин (https://shop.example.invalid)',
                    documentId: doc,
                    requestId: 'request_0123456789',
                    isCurrent: () => true,
                  );
                },
                child: const Text('Запрос'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запрос'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('private@example.invalid'), findsNothing);
      expect(find.text('+79990000001'), findsOneWidget);
      expect(
        find.textContaining('https://shop.example.invalid'),
        findsOneWidget,
      );
      await tester.tap(find.text('+79990000002'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(result?['status'], 'granted');
      expect(result?['phone_number'], '+79990000002');
    },
  );

  testWidgets(
    'contact: session/navigation cancel не выдаёт номер после согласия',
    (tester) async {
      // AC:RL-miniapp-contact/3 AC:RL-miniapp-contact/5
      await setup(tester);
      phones.phones = [
        {'medium': 'msisdn', 'address': '+79990000001'},
      ];
      manager.open(
        appUrl: appUrl,
        appId: 'shop',
        appName: 'Магазин',
        room: room,
        botMxid: botMxid,
        allowDetach: false,
      );
      final app = manager.activeApp!;
      final api = RoomMiniAppHostApi(
        room: room,
        appId: app.appId,
        appUrl: app.appUrl,
        botMxid: app.botMxid,
        interactiveState: app.interactiveState,
        isCurrent: () => app.sessionCurrent && manager.apps.contains(app),
      );
      await api.fetchInitData();
      await api.interactiveRequest('activateDocument', {'document_id': doc});
      Map<String, dynamic>? result;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await requestMiniAppContact(
                    context: context,
                    host: api,
                    recipient: 'Магазин',
                    documentId: doc,
                    requestId: 'request_0123456789',
                    isCurrent: () => manager.isInteractiveVisible(app),
                  );
                },
                child: const Text('Запрос'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запрос'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      // Приложение ушло из-под панели (открыли другое) и вернулось: старое
      // согласие оживать не должно.
      manager.open(
        appUrl: 'https://cafe.example.invalid/',
        appId: 'cafe',
        appName: 'Кафе',
        room: room,
        allowDetach: false,
      );
      manager.open(
        appUrl: appUrl,
        appId: 'shop',
        appName: 'Магазин',
        room: room,
        botMxid: botMxid,
        allowDetach: false,
      );
      await tester.pump(const Duration(milliseconds: 1250));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(result, {'status': 'denied'});
      client.accessToken = 'different-account-session';
      await expectLater(
        api.interactiveRequest('contactPhones', {'document_id': doc}),
        throwsStateError,
      );
    },
  );

  testWidgets(
    'unregistered/unverified origin не получает телефон; stale init response не оживляет host',
    (tester) async {
      // AC:RL-miniapp-contact/4
      await setup(tester);
      final api = host();
      await expectLater(
        api.interactiveRequest('contactPhones', {'document_id': doc}),
        throwsStateError,
      );
      await api.fetchInitData();
      await api.interactiveRequest('activateDocument', {'document_id': doc});
      final foreign = RoomMiniAppHostApi(
        room: room,
        appId: 'shop',
        appUrl: '${appUrl}unregistered-path',
        botMxid: botMxid,
        interactiveState: MiniAppInteractiveState()
          ..authenticated = true
          ..documentId = doc,
      );
      await expectLater(foreign.fetchInitData(), throwsStateError);
      expect(foreign.interactiveState.authenticated, isFalse);
      await expectLater(
        foreign.interactiveRequest('contactPhones', {'document_id': doc}),
        throwsStateError,
      );
      registered = false;
      expect(
        await api.interactiveRequest('contactPhones', {'document_id': doc}),
        {'status': 'unavailable'},
      );
      expect(
        miniAppInteractiveOrigin(appUrl: 'https://app.example/path?start=1'),
        'https://app.example',
      );
      expect(
        miniAppInteractiveOrigin(
          appUrl: 'https://app.example/path',
          shellUrl: 'https://shell.example/host',
        ),
        'https://shell.example',
      );
      expect(miniAppInteractiveOrigin(appUrl: 'http://app.example'), isNull);
      expect(
        miniAppSensitiveOriginAllowed(
          allowedOrigin: miniAppInteractiveOrigin(
            appUrl: 'https://app.example/path',
          ),
          currentUrl: 'https://app.example/started',
          loadedUrl: 'https://app.example/started',
        ),
        isTrue,
      );
      expect(
        miniAppSensitiveOriginAllowed(
          allowedOrigin: 'https://shell.example',
          currentUrl: 'https://evil.example',
          loadedUrl: 'https://shell.example/host',
        ),
        isFalse,
      );
      expect(
        miniAppSensitiveOriginAllowed(
          allowedOrigin: 'https://shell.example',
          currentUrl: 'https://shell.example/host',
          loadedUrl: null,
        ),
        isFalse,
      );
      RoomMiniAppHostApi.transportFactory = () => MockClient((_) async {
        client.accessToken = 'new-session';
        return response({'init_data': 'hash=late'});
      });
      await expectLater(api.fetchInitData(), throwsStateError);
    },
  );
  testWidgets(
    'hidden IndexedStack и detached native snapshot отменяют старые запросы',
    (tester) async {
      // AC:RL-miniapp-contact/5
      await setup(tester);
      manager.open(
        appUrl: appUrl,
        appId: 'shop',
        appName: 'Shop',
        room: room,
        botMxid: botMxid,
        allowDetach: false,
      );
      final app = manager.activeApp!;
      final api = RoomMiniAppHostApi(
        room: room,
        appId: app.appId,
        appUrl: app.appUrl,
        botMxid: app.botMxid,
        interactiveState: app.interactiveState,
      );
      await api.fetchInitData();
      await api.interactiveRequest('activateDocument', {'document_id': doc});
      final binding = {
        'document_id': doc,
        'request_id': 'request_before_hidden',
      };
      expect(
        (await api.interactiveRequest('check', binding))['status'],
        'active',
      );
      manager.open(
        appUrl: appUrl,
        appId: 'other',
        appName: 'Other',
        room: room,
        allowDetach: false,
      );
      await expectLater(
        api.interactiveRequest('check', binding),
        throwsStateError,
      );
      manager.close('other');
      expect(manager.activeAppId, 'shop');
      await expectLater(
        api.interactiveRequest('check', binding),
        throwsStateError,
      );
      expect(
        (await api.interactiveRequest('check', {
          'document_id': doc,
          'request_id': 'new_request_after_show',
        }))['status'],
        'active',
      );

      manager.detach('shop');
      final detached = manager.detachedApps.single;
      final config = MiniAppWindowConfig.of(detached, null);
      final rpc = {
        'app_id': config.appId,
        'content_key': config.contentKey,
        'session_id': config.interactiveSessionId,
        'account_user_id': config.accountUserId,
      };
      var nativeSequence = 0;
      var nativeFocus = 0;
      var nativeMainFocus = 0;
      var directMainFocus = -1;
      Future<void> native(Map<String, Object> snapshot) async {
        if (snapshot['focus_epoch'] is int) {
          nativeFocus = snapshot['focus_epoch'] as int;
        }
        if (snapshot['main_focus_epoch'] is int) {
          nativeMainFocus = snapshot['main_focus_epoch'] as int;
        }
        if (snapshot['direct_main_focus_epoch'] is int) {
          directMainFocus = snapshot['direct_main_focus_epoch'] as int;
        }
        await MiniAppWindows.instance.debugHandleHostCall(
          MethodCall('windowVisibility', {
            ...rpc,
            'snapshot': {
              'visibility_epoch': 0,
              'focus_epoch': nativeFocus,
              'main_focus_epoch': nativeMainFocus,
              'direct_main_focus_epoch': directMainFocus,
              ...snapshot,
              'sequence': ++nativeSequence,
            },
          }),
        );
      }

      const shown = {
        'closed': false,
        'visible': true,
        'minimized': false,
        'focused': true,
        'main_focused': false,
      };
      expect(detached.interactiveState.visible, isFalse);
      await native(shown);
      expect(detached.interactiveState.visible, isTrue);
      final beforeIndirect = detached.interactiveState.visibilityEpoch;
      detached.interactiveState.beginPresentation();
      // A→B→main: final main snapshot пришёл раньше callback о B.
      await native({
        ...shown,
        'focused': false,
        'main_focused': true,
        'focus_epoch': 1,
        'direct_main_focus_epoch': -1,
      });
      expect(detached.interactiveState.visible, isFalse);
      expect(
        detached.interactiveState.visibilityEpoch,
        greaterThan(beforeIndirect),
      );
      final afterIndirect = detached.interactiveState.visibilityEpoch;
      await MiniAppWindows.instance.debugHandleHostCall(
        MethodCall('windowVisibility', {
          ...rpc,
          'snapshot': {
            ...shown,
            'focused': false,
            'visibility_epoch': 0,
            'focus_epoch': 1,
            'main_focus_epoch': 0,
            'direct_main_focus_epoch': -1,
            'sequence': nativeSequence - 1,
          },
        }),
      );
      expect(detached.interactiveState.visibilityEpoch, afterIndirect);
      await native(shown);
      final epoch = detached.interactiveState.visibilityEpoch;
      detached.interactiveState.beginPresentation();
      await native({
        ...shown,
        'focused': false,
        'main_focused': true,
        'focus_epoch': 2,
        'direct_main_focus_epoch': 2,
      });
      expect(
        detached.interactiveState.visible,
        isTrue,
      ); // Наш picker в main engine.
      expect(detached.interactiveState.visibilityEpoch, epoch);
      // Main-picker потерял фокус и вернулся до callback: sticky main epoch.
      await native({
        ...shown,
        'focused': false,
        'main_focused': true,
        'main_focus_epoch': 1,
      });
      expect(detached.interactiveState.visibilityEpoch, greaterThan(epoch));
      detached.interactiveState.presenting = false;
      await native(shown);
      final beforeFocusRoundtrip = detached.interactiveState.visibilityEpoch;
      await native({...shown, 'focus_epoch': 3});
      expect(
        detached.interactiveState.visibilityEpoch,
        greaterThan(beforeFocusRoundtrip),
      );
      await native({...shown, 'minimized': true});
      expect(detached.interactiveState.visible, isFalse);
      expect(detached.interactiveState.visibilityEpoch, greaterThan(epoch));
      await native(shown);
      await native({
        ...shown,
        'focused': false,
      }); // Перешли в стороннее приложение.
      expect(detached.interactiveState.visible, isFalse);
      await native(shown);
      await native({...shown, 'closed': true});
      expect(detached.interactiveState.visible, isFalse);
      await native(shown);
      final beforeQuickRestore = detached.interactiveState.visibilityEpoch;
      // Native успел скрыть и вернуть окно до доставки callback: epoch это помнит.
      await native({...shown, 'visibility_epoch': 1});
      expect(detached.interactiveState.visible, isTrue);
      expect(
        detached.interactiveState.visibilityEpoch,
        greaterThan(beforeQuickRestore),
      );
      await MiniAppWindows.instance.debugHandleHostCall(
        MethodCall('windowVisibility', {
          ...rpc,
          'snapshot': {
            ...shown,
            'closed': true,
            'visibility_epoch': 0,
            'sequence': 0,
          },
        }),
      );
      expect(
        detached.interactiveState.visible,
        isTrue,
      ); // Устаревший callback отвергнут.
    },
  );
}
