// Явный живой proof: запускается только conformance harness с 0600 config.
// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-api-interactive-client
// ledger:RL-bot-deep-links
// AC:RL-bot-api-interactive-client/14
// AC:RL-bot-api-interactive-client/15
// AC:RL-bot-api-interactive-client/16
// AC:RL-bot-api-interactive-client/17
// AC:RL-bot-deep-links/8
// ledger:RL-bot-api-inline-queries-client
// AC:RL-bot-api-inline-queries-client/7
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/pending_deep_link.dart';
import 'package:liza/widgets/interactive_bot_composer.dart';
import 'package:liza/widgets/interactive_bot_permissions.dart';
import 'package:liza/widgets/matrix.dart';

class _LiveOverrides extends HttpOverrides {}

Uri _loopback(String value) {
  final uri = Uri.parse(value);
  if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
    throw StateError('Only isolated loopback fixtures allowed');
  }
  return uri;
}

/// Только URL fixture и потеря настоящего принятого ответа. Ответы не подменяются.
class _Transport extends http.BaseClient {
  final http.Client inner = http.Client();
  final Uri? api;
  bool loseStartResponse = false;
  bool startResponseLost = false;
  final startTxids = <String>[];
  final startEvents = <String>[];
  int phoneLoads = 0;
  int sendFailures = 0;
  _Transport({this.api});
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final target =
        api?.replace(
          path: request.url.path,
          query: request.url.hasQuery ? request.url.query : null,
        ) ??
        request.url;
    _loopback(target.toString());
    final forwarded = http.Request(request.method, target)
      ..headers.addAll(request.headers)
      ..followRedirects = false
      ..bodyBytes = bytes;
    final response = await inner.send(forwarded);
    if (request.url.path.endsWith('/account/3pid')) phoneLoads++;
    if (request.url.path.contains('/send/m.room.message/') &&
        response.statusCode >= 400) {
      sendFailures++;
    }
    if (request.url.path.contains('/send/m.room.message/') &&
        bytes.isNotEmpty) {
      final body = jsonDecode(utf8.decode(bytes));
      if (body is Map &&
          body['body'] is String &&
          (body['body'] as String).startsWith('/start ')) {
        startTxids.add(request.url.pathSegments.last);
        if (response.statusCode == 200 &&
            loseStartResponse &&
            !startResponseLost) {
          final committed = jsonDecode(await response.stream.bytesToString());
          startEvents.add(committed['event_id'] as String);
          startResponseLost = true;
          throw http.ClientException(
            'Intentional lost committed start response',
          );
        }
      }
    }
    return response;
  }

  @override
  void close() => inner.close();
}

/// Только Provider-оболочка: реальный Client, комнаты, сеть и SDK не заменены.
class _MatrixContext extends MatrixState {
  final Client live;
  final SharedPreferences preferences;
  bool signedIn = true;
  _MatrixContext(this.live, this.preferences);
  @override
  Client get client => live;
  @override
  Matrix get widget =>
      Matrix(clients: signedIn ? [live] : [], store: preferences);
}

void main() {
  testWidgets(
    'живые consent/composer/picker/permissions/router с Matrix',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        const configPath = String.fromEnvironment('BOT_API_LIVE_UI_CONFIG');
        if (configPath.isEmpty) {
          throw StateError('Explicit live UI config required');
        }
        late Map<String, dynamic> config;
        await tester.runAsync(() async {
          config =
              jsonDecode(await File(configPath).readAsString())
                  as Map<String, dynamic>;
        });
        final apiUrl = _loopback(config['api_url'] as String);
        BotInteractiveApi.transportFactory = () => _Transport(api: apiUrl);
        final transports = <_Transport>[];
        final clients = <Client>[];
        final timelines = <Timeline>[];
        final result = <String, dynamic>{};
        final checks = <String>[];
        Future<Client> connect(String key) async {
          final actor = config[key] as Map;
          final transport = _Transport();
          transports.add(transport);
          final client = Client(
            'Liza live UI $key',
            httpClient: transport,
            database: await MatrixSdkDatabase.init(
              'ui-$key',
              database: await databaseFactoryFfi.openDatabase(
                ':memory:',
                options: OpenDatabaseOptions(singleInstance: false),
              ),
              sqfliteFactory: databaseFactoryFfi,
            ),
          );
          clients.add(client);
          client.backgroundSync = false;
          await client.init(
            newToken: actor['access_token'] as String,
            newUserID: actor['user_id'] as String,
            newHomeserver: _loopback(actor['homeserver'] as String),
            newDeviceID: actor['device_id'] as String?,
            newDeviceName: 'Liza live UI proof',
          );
          return client;
        }

        Future<void> drive(
          bool Function() done,
          String name, {
          int seconds = 15,
        }) async {
          final clock = Stopwatch()..start();
          while (!done() && clock.elapsed < Duration(seconds: seconds)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 60)),
            );
            await tester.pump(const Duration(milliseconds: 60));
          }
          expect(done(), isTrue, reason: name);
        }

        bool keyboardReady(String label) {
          final button = find.widgetWithText(OutlinedButton, label);
          return button.evaluate().length == 1 &&
              tester.widget<OutlinedButton>(button).onPressed != null;
        }

        late Client owner;
        late Client subscriber;
        late BuildContext context;
        Widget shell(Widget child) => MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return child;
              },
            ),
          ),
        );
        final controllers = <TextEditingController>[];
        Future<(Room, Timeline)> mountComposer(
          Client client,
          String key, {
          bool waitKeyboard = true,
        }) async {
          final roomId = (config['rooms'] as Map)[key] as String;
          late Room room;
          late Timeline timeline;
          await tester.runAsync(() async {
            room = client.getRoomById(roomId)!;
            timeline = await room.getTimeline();
            if (!timeline.events.any(
              (e) => e.content['com.liza.bot_markup'] != null,
            )) {
              await timeline.requestHistory(historyCount: 100);
            }
          });
          timelines.add(timeline);
          final controller = TextEditingController();
          controllers.add(controller);
          await tester.pumpWidget(
            shell(
              InteractiveBotComposer(
                key: UniqueKey(),
                room: room,
                timeline: timeline,
                controller: controller,
                onForceReply: (_) {},
                onOpenApp: (_) async {},
                onSent: () {},
              ),
            ),
          );
          if (waitKeyboard) {
            await drive(
              () => find.byType(OutlinedButton).evaluate().isNotEmpty,
              'registered keyboard $key',
            );
          }
          return (room, timeline);
        }

        Future<List<Map<String, dynamic>>> messages(Room room) async {
          final uri = room.client.homeserver!
              .resolve(
                '/_matrix/client/v3/rooms/${Uri.encodeComponent(room.id)}/messages',
              )
              .replace(queryParameters: {'dir': 'b', 'limit': '100'});
          final response = await http.get(
            uri,
            headers: {'Authorization': 'Bearer ${room.client.accessToken}'},
          );
          expect(response.statusCode, 200);
          return (jsonDecode(response.body)['chunk'] as List)
              .cast<Map<String, dynamic>>();
        }

        Future<Map<String, dynamic>> waitMessage(
          Room room,
          bool Function(Map<String, dynamic>) matches,
        ) async {
          Map<String, dynamic>? found;
          for (var i = 0; i < 100 && found == null; i++) {
            await tester.runAsync(() async {
              found = (await messages(room)).where(matches).firstOrNull;
              if (found == null) {
                await Future<void>.delayed(const Duration(milliseconds: 80));
              }
            });
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(found, isNotNull, reason: 'real Matrix effect');
          return found!;
        }

        try {
          await tester.runAsync(() async {
            owner = await connect('owner');
            subscriber = await connect('subscriber');
          });
          final bot = config['bot_mxid'] as String;
          final phone = config['phone'] as String;
          final contactLabel = config['contact_label'] as String;
          final (contactRoom, _) = await mountComposer(owner, 'contact');
          await tester.tap(find.text(contactLabel));
          await drive(
            () => find.text(phone).evaluate().isNotEmpty,
            'real 3PID consent',
          );
          expect(transports.first.phoneLoads, greaterThan(0));
          expect(find.textContaining(bot), findsOneWidget);
          await tester.tap(find.text('Отмена'));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.runAsync(() async {
            expect(
              (await messages(contactRoom)).where(
                (e) =>
                    e['sender'] == owner.userID &&
                    (e['content'] as Map).containsKey('com.liza.contact'),
              ),
              isEmpty,
            );
          });
          await tester.tap(find.text(contactLabel));
          await drive(
            () => find.text(phone).evaluate().isNotEmpty,
            'second consent',
          );
          await tester.tap(find.text(phone));

          final contactEvent = await waitMessage(
            contactRoom,
            (e) =>
                e['sender'] == owner.userID &&
                (e['content'] as Map).containsKey('com.liza.contact'),
          );
          expect(
            contactEvent['content']['com.liza.contact']['phone_number'],
            phone,
          );
          result['contact_event_id'] = contactEvent['event_id'];
          await drive(
            () => keyboardReady(contactLabel),
            'contact send completes in SDK',
          );
          await tester.tap(find.text(contactLabel));
          await drive(
            () => find.text(phone).evaluate().isNotEmpty,
            'context-change consent',
          );
          await tester.pumpWidget(shell(const SizedBox()));
          await tester.pump(const Duration(milliseconds: 450));
          final (_, _) = await mountComposer(subscriber, 'contact');
          await tester.tap(find.text(contactLabel));
          await drive(
            () => find
                .text(L10n.of(context).botContactUnavailable)
                .evaluate()
                .isNotEmpty,
            'real no-msisdn result',
          );
          await tester.runAsync(() async {
            final actual = await messages(contactRoom);
            final contacts = actual
                .where(
                  (e) => (e['content'] as Map).containsKey('com.liza.contact'),
                )
                .toList();
            expect(contacts, hasLength(1));
            expect(contacts.single['sender'], owner.userID);
          });
          debugPrint('LIVE_UI contact checks complete');
          checks.add(
            'real_msisdn_consent_allow_deny_unavailable_context_change',
          );

          final label = config['one_time_label'] as String;
          final (keyboardRoom, _) = await mountComposer(owner, 'one_time');
          await tester.tap(find.text(label));
          final keyboardEvent = await waitMessage(
            keyboardRoom,
            (e) =>
                e['sender'] == owner.userID &&
                (e['content']['body'] as String? ?? '').endsWith(label),
          );
          await drive(
            () => find.text(label).evaluate().isEmpty,
            'one_time hides only after send',
          );
          await tester.pumpWidget(shell(const SizedBox()));
          late Timeline reentry;
          await tester.runAsync(() async {
            reentry = await keyboardRoom.getTimeline();
          });
          timelines.add(reentry);
          final reentryController = TextEditingController();
          controllers.add(reentryController);
          await tester.pumpWidget(
            shell(
              InteractiveBotComposer(
                key: UniqueKey(),
                room: keyboardRoom,
                timeline: reentry,
                controller: reentryController,
                onForceReply: (_) {},
                onOpenApp: (_) async {},
                onSent: () {},
              ),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(label), findsNothing);
          result['one_time_event_id'] = keyboardEvent['event_id'];
          await mountComposer(owner, 'failed');
          final failures = transports.first.sendFailures;
          await tester.tap(find.text(config['failed_label'] as String));
          await drive(
            () => transports.first.sendFailures > failures,
            'real Matrix403',
          );
          await tester.pump(const Duration(milliseconds: 400));
          await drive(
            () => keyboardReady(config['failed_label'] as String),
            'forbidden send settles',
          );
          expect(find.text(config['failed_label'] as String), findsOneWidget);
          await mountComposer(owner, 'failed');
          expect(find.text(config['failed_label'] as String), findsOneWidget);
          debugPrint('LIVE_UI one_time checks complete');
          checks.add(
            'one_time_real_send_reentry_and_forbidden_send_not_hidden',
          );

          await mountComposer(owner, 'users');
          await tester.tap(find.text(config['users_label'] as String));
          await drive(
            () => find.byType(CheckboxListTile).evaluate().isNotEmpty,
            'real joined-user picker',
          );
          await tester.tap(find.text('Отмена'));
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(config['users_label'] as String), findsOneWidget);
          await drive(
            () => keyboardReady(config['users_label'] as String),
            'cancelled picker settles',
          );
          await tester.tap(find.text(config['users_label'] as String));
          await drive(
            () => find.byType(CheckboxListTile).evaluate().isNotEmpty,
            'second real user picker after cancel',
          );
          await tester.tap(find.text(subscriber.userID!));
          await tester.pump();
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, L10n.of(context).send),
                )
                .onPressed,
            isNotNull,
          );
          await tester.tap(
            find.widgetWithText(FilledButton, L10n.of(context).send),
          );
          await drive(
            () => find.text(config['users_label'] as String).evaluate().isEmpty,
            'real users_shared submit',
          );
          debugPrint('LIVE_UI users checks complete');
          checks.add('request_users_real_joined_selection_update');

          final api = BotInteractiveApi(owner);
          late RegisteredBot registered;
          await tester.runAsync(() async {
            registered = (await api.resolve(mxid: bot, force: true))!;
          });
          for (final level in [0, 50, 99, -1]) {
            final room = owner.getRoomById(
              (config['rooms'] as Map)['invite_$level'] as String,
            )!;
            await tester.pumpWidget(shell(const SizedBox()));
            final choice = chooseBotInvitePermissions(
              context: context,
              room: room,
              botMxid: bot,
              bot: registered,
              isCurrent: () => true,
            );
            await tester.pump(const Duration(milliseconds: 400));
            if (level < 0) {
              Navigator.of(context, rootNavigator: true).pop();
            } else {
              final strings = L10n.of(context);
              await tester.tap(
                find.text(
                  level == 0
                      ? strings.normalUser
                      : level == 50
                      ? strings.moderator
                      : strings.admin,
                ),
              );
            }
            await tester.pump(const Duration(milliseconds: 400));
            final selected = await choice;
            expect(selected, level < 0 ? isNull : level);
            if (selected != null) {
              await tester.runAsync(() async {
                await inviteBotWithPermissions(room, bot, selected);
              });
            }
            await tester.runAsync(() async {
              final power = await owner.getRoomStateWithKey(
                room.id,
                EventTypes.RoomPowerLevels,
                '',
              );
              expect(
                (power['users'] as Map)[bot] ?? power['users_default'] ?? 0,
                level < 0 ? 0 : level,
              );
            });
          }
          debugPrint('LIVE_UI permission checks complete');
          checks.add('explicit_invite_levels_0_50_99_cancel_real_power_state');

          final (inlineRoom, _) = await mountComposer(
            owner,
            'inline',
            waitKeyboard: false,
          );
          controllers.last.text =
              '@${config['bot_username']} ${config['inline_query']}';
          await drive(
            () => find
                .text(config['inline_title'] as String)
                .evaluate()
                .isNotEmpty,
            'real inline results in production composer',
            seconds: 20,
          );
          await tester.runAsync(() async {
            expect(
              (await messages(inlineRoom)).where(
                (e) =>
                    e['sender'] == owner.userID &&
                    e['type'] == EventTypes.Message,
              ),
              isEmpty,
            );
          });
          await tester.tap(find.text(config['inline_title'] as String));
          final inlineEvent = await waitMessage(
            inlineRoom,
            (e) =>
                e['sender'] == owner.userID &&
                e['content']['body'] == config['inline_query'],
          );
          await drive(
            () =>
                find.text(config['inline_title'] as String).evaluate().isEmpty,
            'inline ACK finishes before closing composer',
          );
          result['inline_event_id'] = inlineEvent['event_id'];
          debugPrint('LIVE_UI inline visible selection checks complete');
          checks.add(
            'production_inline_composer_visible_results_selection_matrix_chosen',
          );

          final startRoomId = (config['rooms'] as Map)['start'] as String;
          expect(
            owner.getDirectChatFromUserId(bot),
            startRoomId,
            reason: 'real m.direct initial sync precondition',
          );
          await tester.runAsync(() async {
            await owner.getRoomById(startRoomId)!.requestParticipants([
              Membership.join,
            ]);
          });
          expect(
            owner
                .getRoomById(startRoomId)!
                .getState(EventTypes.RoomMember, bot)
                ?.content['membership'],
            'join',
            reason: 'real joined bot state before start tap',
          );

          // Только платформа preferences заменена памятью host-теста; настоящий
          // redirect/pageBuilder AppRoutes, reload reset и реальный descriptor.
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final matrixContext = _MatrixContext(owner, preferences);
          final botRoute = AppRoutes.routes.whereType<GoRoute>().singleWhere(
            (r) => r.path == '/b/:username',
          );
          final username = config['bot_username'] as String;
          final parameter = config['start_parameter'] as String;
          final router = GoRouter(
            initialLocation: '/b/$username?start=$parameter',
            routes: [
              botRoute,
              GoRoute(
                path: '/home',
                builder: (_, _) => const Scaffold(body: Text('fixture login')),
              ),
              GoRoute(
                path: '/rooms/:id',
                builder: (_, _) => const Scaffold(body: Text('fixture room')),
              ),
              GoRoute(
                path: '/rooms',
                builder: (_, _) => const Scaffold(body: Text('fixture rooms')),
              ),
            ],
          );
          Widget routerShell() => Provider<MatrixState>.value(
            value: matrixContext,
            child: MaterialApp.router(
              locale: const Locale('ru'),
              routerConfig: router,
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
            ),
          );
          matrixContext.signedIn = false;
          await tester.pumpWidget(routerShell());
          await drive(
            () => find.text('fixture login').evaluate().isNotEmpty,
            'production logged-out redirect',
          );
          expect(
            PendingDeepLinkStore.current?.code,
            '/b/$username?start=$parameter',
          );
          await tester.pump();
          PendingDeepLinkStore.debugResetInMemory();
          final restored = await PendingDeepLinkStore.restore();
          expect(restored?.code, '/b/$username?start=$parameter');
          matrixContext.signedIn = true;
          router.go(restored!.code);
          await drive(
            () => find
                .widgetWithText(FilledButton, 'Запустить')
                .evaluate()
                .isNotEmpty,
            'real registered start page',
          );
          transports.first.loseStartResponse = true;
          await tester.tap(find.widgetWithText(FilledButton, 'Запустить'));
          await drive(
            () => transports.first.startResponseLost,
            'real committed /start response loss',
            seconds: 25,
          );
          await drive(
            () =>
                router.routeInformationProvider.value.uri.path.startsWith(
                  '/rooms/',
                ) ||
                find
                    .text('Не удалось запустить бота. Повторите попытку.')
                    .evaluate()
                    .isNotEmpty,
            'SDK retry or explicit failed state',
          );
          if (find
              .text('Не удалось запустить бота. Повторите попытку.')
              .evaluate()
              .isNotEmpty) {
            await tester.pump(const Duration(milliseconds: 400));
            await tester.tap(find.widgetWithText(FilledButton, 'Запустить'));
          }
          await drive(
            () => find.text('fixture room').evaluate().isNotEmpty,
            'start sent with stable transaction',
            seconds: 25,
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(transports.first.startTxids.toSet(), hasLength(1));
          expect(transports.first.startTxids.length, greaterThanOrEqualTo(2));
          result['start_event_id'] = transports.first.startEvents.single;
          result['start_txids'] = transports.first.startTxids;
          final beforeUnknown = transports.first.startTxids.length;
          router.go('/b/unknown_live_${config['nonce']}?start=no_send');
          await drive(
            () => find.text('Бот недоступен').evaluate().isNotEmpty,
            'unknown bot no action',
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(FilledButton), findsNothing);
          expect(transports.first.startTxids.length, beforeUnknown);
          matrixContext.signedIn = false;
          router.go('/b/$username?startapp=launch_param');
          await drive(
            () => find.text('fixture login').evaluate().isNotEmpty,
            'startapp login preservation',
          );
          await tester.pump();
          PendingDeepLinkStore.debugResetInMemory();
          final startapp = await PendingDeepLinkStore.restore();
          expect(startapp?.code, '/b/$username?startapp=launch_param');
          matrixContext.signedIn = true;
          router.go(startapp!.code);
          await drive(
            () => find
                .widgetWithText(FilledButton, 'Открыть мини-приложение')
                .evaluate()
                .isNotEmpty,
            'startapp page after login',
          );
          final app = registered.appForUrl(config['app_url'] as String);
          expect(app?.appId, config['app_id']);
          expect(app?.botMxid, bot);
          expect(
            registered.appForUrl('https://foreign.example.test/app'),
            isNull,
          );
          result['published_app_id'] = app!.appId;
          checks.add(
            'production_router_login_reload_start_startapp_published_binding',
          );
          checks.add('bot_start_page_real_matrix_stable_txid_unknown_no_send');
          await tester.pumpWidget(const SizedBox());
          router.dispose();
          debugPrint('LIVE_UI routing and start checks complete');
          await tester.runAsync(() async {
            expect(await api.resolve(mxid: bot, force: true), isNotNull);
          });
          final (_, usersReentry) = await mountComposer(
            owner,
            'users',
            waitKeyboard: false,
          );
          final sources = usersReentry.events
              .where(
                (e) =>
                    e.senderId == bot &&
                    e.content['com.liza.bot_markup'] != null,
              )
              .toList();
          expect(
            sources,
            hasLength(1),
            reason: 'reentry must actually contain original bot keyboard',
          );
          expect(
            usersReentry.events.where(
              (e) =>
                  e.senderId == owner.userID &&
                  e.status.isSent &&
                  e.type == EventTypes.Message,
            ),
            isEmpty,
            reason: 'private submit has no timeline reply',
          );
          for (var pass = 0; pass < 5; pass++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            find.text(config['users_label'] as String),
            findsNothing,
            reason: 'private users_shared one_time survives reentry',
          );
          debugPrint('LIVE_UI private one_time reentry complete');
          api.dispose();
          result['checks'] = checks;
          result['scope'] =
              'host widgets + real loopback Matrix/APIServer; no native permission or WebView execution';
          await tester.runAsync(
            () => File(
              config['result_path'] as String,
            ).writeAsString(jsonEncode(result)),
          );
        } finally {
          await tester.pumpWidget(const SizedBox());
          for (final timeline in timelines) {
            timeline.cancelSubscriptions();
          }
          for (final controller in controllers) {
            controller.dispose();
          }
          BotInteractiveApi.transportFactory = http.Client.new;
          await tester.runAsync(() async {
            for (final client in clients) {
              await client.dispose();
            }
            for (final transport in transports) {
              transport.close();
            }
          });
        }
      }, _LiveOverrides());
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
