// ignore_for_file: depend_on_referenced_packages
// ledger:RL-support-menu-navigation
// guard.render:real-widget — настоящий ChatInputRow, подменены только зависимости.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/chat_input_row.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/formatting_text_controller.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/widgets/interactive_bot_menu.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/test_client.dart';

class _MatrixHarness extends MatrixState {
  _MatrixHarness(this.testClient);
  final Client testClient;
  @override
  Client get client => testClient;
  @override
  bool get isMultiAccount => false;
}

class _ControllerHarness extends ChatController {
  _ControllerHarness(this.currentRoom) {
    inputFocus = FocusNode();
    sendingClient = currentRoom.client;
  }
  Room currentRoom;
  @override
  Room get room => currentRoom;
  @override
  void onInputBarChanged(String text) {}
}

class _SendRoom extends Room {
  _SendRoom({required super.id, required super.client})
    : super(membership: Membership.join);
  final sends = <Map<String, Object?>>[];
  Completer<String?>? result;
  @override
  Future<String?> sendTextEvent(
    String message, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    bool parseMarkdown = true,
    bool parseCommands = true,
    String msgtype = MessageTypes.Text,
    String? threadRootEventId,
    String? threadLastEventId,
    StringBuffer? commandStdout,
    bool addMentions = true,
    bool displayPendingEvent = true,
  }) async {
    sends.add({
      'message': message,
      'parseCommands': parseCommands,
      'reply': inReplyTo,
      'edit': editEventId,
      'thread': threadRootEventId,
    });
    return result == null ? r'$menu' : await result!.future;
  }
}

Future<(_SendRoom, _ControllerHarness)> _setup(
  WidgetTester tester, {
  String host = 'synapse.liza.laba.prodamus.tech',
  String? peer = '@support:bots.liza.ru',
}) async {
  late Client client;
  await tester.runAsync(() async {
    client = await prepareTestClient(
      loggedIn: true,
      homeserver: Uri.https(host),
    );
  });
  client.backgroundSync = false;
  addTearDown(() => tester.runAsync(() => client.dispose(closeDatabase: true)));
  client.rooms.clear();
  final room = _SendRoom(id: '!support:$host', client: client);
  client.rooms.add(room);
  if (peer != null) {
    room.setState(
      StrippedStateEvent(
        senderId: peer,
        type: EventTypes.RoomMember,
        stateKey: peer,
        content: {'membership': 'join', 'displayname': peer},
      ),
    );
  }
  client.accountData['m.direct'] = BasicEvent(
    type: 'm.direct',
    content: {
      if (peer != null) peer: [room.id],
    },
  );
  final controller = _ControllerHarness(room);
  addTearDown(controller.sendController.dispose);
  addTearDown(controller.inputFocus.dispose);
  addTearDown(controller.scrollController.dispose);
  return (room, controller);
}

Future<void> _mount(
  WidgetTester tester,
  _ControllerHarness controller, {
  String locale = 'ru',
  double scale = 1,
  String? fontFamily,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(locale),
      theme: ThemeData(fontFamily: fontFamily),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<MatrixState>.value(
        value: _MatrixHarness(controller.room.client),
        child: RepaintBoundary(
          key: const Key("support-composer-image"),
          child: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller.sendController,
                  builder: (context, _, _) => ChatInputRow(controller),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Finder get _specialMenu => find.widgetWithText(TextButton, 'Меню');

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    await L10n.delegate.load(const Locale('ru'));
    await L10n.delegate.load(const Locale('en'));
    if (Platform.environment['SUPPORT_MENU_VISUAL_DIR'] != null) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  setUp(() {
    BotInteractiveApi.transportFactory = () =>
        MockClient((_) async => http.Response(jsonEncode({'bots': []}), 200));
  });
  tearDown(() => BotInteractiveApi.transportFactory = http.Client.new);

  testWidgets(
    'доверенный DM показывает специальное Меню вместо generic picker',
    (tester) async {
      // AC:RL-support-menu-navigation/1
      // AC:RL-support-menu-navigation/2
      final (_, controller) = await _setup(tester);
      await _mount(tester, controller);
      expect(find.byType(ChatInputRow), findsOneWidget);
      expect(_specialMenu, findsOneWidget);
      expect(find.byType(InteractiveBotMenu), findsNothing);
    },
  );

  for (final (host, peer) in [
    ('synapse.liza.laba.prodamus.tech', '@support:bots.liza.ru'),
    ('company.liza.ru', '@support:bots.liza.ru'),
    ('localhost', '@support:liza.local'),
  ]) {
    testWidgets('полный account-specific MXID: $host', (tester) async {
      // AC:RL-support-menu-navigation/1
      // AC:RL-support-menu-navigation/2
      final (room, controller) = await _setup(tester, host: host, peer: peer);
      // Registry недоступен — специальная кнопка остаётся независимой от него.
      BotInteractiveApi.transportFactory = () =>
          MockClient((_) async => http.Response('unavailable', 503));
      await _mount(tester, controller);
      expect(isSupportBotDm(room), isTrue);
      expect(_specialMenu, findsOneWidget);
      expect(find.byType(InteractiveBotMenu), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (host, peer) in [
    ('localhost', '@support:bots.liza.ru'),
    ('company.liza.ru', '@support:liza.local'),
  ]) {
    testWidgets('бот другого контура $peer не trusted DM на $host', (
      tester,
    ) async {
      // AC:RL-support-menu-navigation/3
      final (room, controller) = await _setup(tester, host: host, peer: peer);
      await _mount(tester, controller);
      expect(isSupportBotDm(room), isFalse);
      expect(_specialMenu, findsNothing);
    });
  }

  for (final peer in [
    '@support:foreign.example',
    '@person:bots.liza.ru',
    null,
  ]) {
    testWidgets('чужой support/человек/группа не получают DM-кнопку: $peer', (
      tester,
    ) async {
      // AC:RL-support-menu-navigation/3
      final (room, controller) = await _setup(tester, peer: peer);
      room.setState(
        StrippedStateEvent(
          senderId: room.client.userID!,
          type: EventTypes.RoomName,
          stateKey: '',
          content: {'name': 'Поддержка'},
        ),
      );
      await _mount(tester, controller);
      expect(isSupportBotDm(room), isFalse);
      expect(_specialMenu, findsNothing);
      expect(find.byType(InteractiveBotMenu), findsOneWidget);
    });
  }

  for (final membership in ['unknown', 'leave', 'ban']) {
    testWidgets('AC3: $membership не доказывает третий активный membership', (
      tester,
    ) async {
      // AC:RL-support-menu-navigation/1
      // AC:RL-support-menu-navigation/3
      final (room, controller) = await _setup(tester);
      if (membership == 'unknown') {
        room.states.remove(EventTypes.RoomMember);
        expect(room.getParticipants(), isEmpty);
      } else {
        room.setState(
          StrippedStateEvent(
            senderId: room.client.userID!,
            type: EventTypes.RoomMember,
            stateKey: '@third:example.invalid',
            content: {'membership': membership},
          ),
        );
      }
      await _mount(tester, controller);
      expect(room.directChatMatrixID, '@support:bots.liza.ru');
      expect(_specialMenu, findsOneWidget);
    });
  }

  for (final membership in ['invite', 'join']) {
    testWidgets(
      'AC3: третий $membership при сохранённом m.direct скрывает DM меню',
      (tester) async {
        // AC:RL-support-menu-navigation/3
        final (room, controller) = await _setup(tester);
        room.setState(
          StrippedStateEvent(
            senderId: room.client.userID!,
            type: EventTypes.RoomMember,
            stateKey: room.client.userID!,
            content: {'membership': 'join'},
          ),
        );
        await _mount(tester, controller);
        expect(room.getParticipants(), hasLength(2));
        expect(room.directChatMatrixID, '@support:bots.liza.ru');
        expect(_specialMenu, findsOneWidget);

        room.setState(
          StrippedStateEvent(
            senderId: room.client.userID!,
            type: EventTypes.RoomMember,
            stateKey: '@third:example.invalid',
            content: {'membership': membership},
          ),
        );
        await _mount(tester, controller);
        expect(room.getParticipants(), hasLength(3));
        expect(
          room.directChatMatrixID,
          '@support:bots.liza.ru',
          reason: 'SDK m.direct остаётся при добавлении участника',
        );
        expect(
          _specialMenu,
          findsNothing,
          reason: 'известный третий участник исключает личный чат поддержки',
        );
        room.setState(
          StrippedStateEvent(
            senderId: room.client.userID!,
            type: EventTypes.RoomMember,
            stateKey: '@third:example.invalid',
            content: {'membership': 'leave'},
          ),
        );
        await _mount(tester, controller);
        expect(room.getParticipants(), hasLength(2));
        expect(room.directChatMatrixID, '@support:bots.liza.ru');
        expect(
          _specialMenu,
          findsOneWidget,
          reason: 'после ухода третьего снова доступно меню исходного DM',
        );
      },
    );
  }

  testWidgets('per-ticket группа с доверенным ботом не становится DM меню', (
    tester,
  ) async {
    // AC:RL-support-menu-navigation/3
    final (room, controller) = await _setup(tester, peer: null);
    room.setState(
      StrippedStateEvent(
        senderId: room.client.userID!,
        type: EventTypes.RoomName,
        stateKey: '',
        content: {'name': 'Обращение №123'},
      ),
    );
    room.setState(
      StrippedStateEvent(
        senderId: room.client.userID!,
        type: EventTypes.RoomMember,
        stateKey: '@support:bots.liza.ru',
        content: {'membership': 'join'},
      ),
    );
    await _mount(tester, controller);
    expect(isSupportBotDm(room), isFalse);
    expect(isSupportHubRoom(room), isFalse);
    expect(_specialMenu, findsNothing);
  });

  testWidgets(
    'literal /menu адресован исходной комнате и сохраняет reply/edit',
    (tester) async {
      // AC:RL-support-menu-navigation/4
      // AC:RL-support-menu-navigation/5
      final (room, controller) = await _setup(tester);
      final reference = Event(
        eventId: r'$original',
        senderId: '@person:x',
        originServerTs: DateTime(2026),
        type: EventTypes.Message,
        content: {'msgtype': 'm.text', 'body': 'исходный текст'},
        room: room,
      );
      controller.replyEvent = reference;
      controller.editEvent = reference;
      controller.activeThreadId = r'$thread';
      await AppSettings.store.setString(
        'draft_${room.id}',
        'сохранённый черновик',
      );
      room.result = Completer<String?>();
      await _mount(tester, controller);
      await tester.tap(_specialMenu);
      await tester.pump();
      expect(room.sends, [
        {
          'message': '/menu',
          'parseCommands': false,
          'reply': null,
          'edit': null,
          'thread': null,
        },
      ]);
      expect(controller.sendController.text, isEmpty);
      expect(controller.replyEvent, same(reference));
      expect(controller.editEvent, same(reference));

      await tester.enterText(find.byType(TextField), 'текст во время отправки');
      controller.sendController.setSpans([
        FormatSpan(0, 5, MessageFormat.bold),
      ], controller.sendController.text.length);
      final draft = controller.sendController.value;
      final spans = controller.sendController.spans
          .map((span) => span.toJson())
          .toList();
      room.result!.complete(r'$sent');
      await tester.pump();
      expect(controller.sendController.value, draft);
      expect(
        controller.sendController.spans.map((span) => span.toJson()),
        spans,
      );
      expect(controller.replyEvent, same(reference));
      expect(controller.editEvent, same(reference));
      expect(controller.activeThreadId, r'$thread');
      expect(
        AppSettings.store.getString('draft_${room.id}'),
        'сохранённый черновик',
      );
      expect(room.sends, hasLength(1));
    },
  );

  for (final failure in ['null', 'throw']) {
    testWidgets(
      '$failure даёт локализованную ошибку без потери нового текста',
      (tester) async {
        // AC:RL-support-menu-navigation/5
        // AC:RL-support-menu-navigation/6
        final (room, controller) = await _setup(tester);
        room.result = Completer<String?>();
        await _mount(tester, controller);
        await tester.tap(_specialMenu);
        await tester.enterText(find.byType(TextField), 'черновик');
        final draft = controller.sendController.value;
        if (failure == 'throw') {
          room.result!.completeError(StateError('SDK failure'));
        } else {
          room.result!.complete(null);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final l10n = L10n.of(tester.element(find.byType(ChatInputRow)));
        expect(find.text(l10n.oopsSomethingWentWrong), findsOneWidget);
        expect(controller.sendController.value, draft);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final change in ['dispose', 'room', 'account', 'session']) {
    testWidgets('поздняя ошибка после $change не появляется', (tester) async {
      // AC:RL-support-menu-navigation/6
      final (room, controller) = await _setup(tester);
      room.result = Completer<String?>();
      await _mount(tester, controller);
      await tester.tap(_specialMenu);
      if (change == 'dispose') {
        await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      } else if (change == 'session') {
        room.client.accessToken = 'changed-test-session';
      } else {
        final client = change == 'account'
            ? (await _setup(tester, host: 'other-company.liza.ru')).$1.client
            : room.client;
        controller.currentRoom = _SendRoom(
          id: change == 'account' ? room.id : '!other:example',
          client: client,
        );
        controller.sendingClient = client;
        await _mount(tester, controller);
      }
      room.result!.completeError(StateError('late SDK failure'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SnackBar), findsNothing);
      expect(room.sends, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('непустой composer скрывает Меню и очистка возвращает его', (
    tester,
  ) async {
    // AC:RL-support-menu-navigation/7
    final (_, controller) = await _setup(tester);
    await _mount(tester, controller);
    expect(_specialMenu, findsOneWidget);
    await tester.enterText(find.byType(TextField), 'черновик');
    await tester.pump();
    expect(_specialMenu, findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(_specialMenu, findsOneWidget);
  });

  for (final kind in ['BotFather', 'hub', 'bot']) {
    testWidgets('смежное меню $kind сохранено', (tester) async {
      // AC:RL-support-menu-navigation/7
      final (room, controller) = await _setup(
        tester,
        peer: kind == 'BotFather'
            ? '@botfather:bots.liza.ru'
            : kind == 'bot'
            ? '@shop:bots.liza.ru'
            : null,
      );
      if (kind == 'hub') {
        room.setState(
          StrippedStateEvent(
            senderId: room.client.userID!,
            type: EventTypes.RoomName,
            stateKey: '',
            content: {'name': 'Liza support hub'},
          ),
        );
        room.setState(
          StrippedStateEvent(
            senderId: room.client.userID!,
            type: EventTypes.RoomMember,
            stateKey: '@support:bots.liza.ru',
            content: {'membership': 'join'},
          ),
        );
      }
      await _mount(tester, controller);
      if (kind == 'bot') {
        expect(_specialMenu, findsNothing);
        expect(find.byType(InteractiveBotMenu), findsOneWidget);
      } else {
        expect(_specialMenu, findsOneWidget);
        expect(find.byType(InteractiveBotMenu), findsNothing);
        await tester.tap(_specialMenu);
        await tester.pump();
        expect(room.sends.single['message'], '/menu');
        expect(room.sends.single['parseCommands'], false);
      }
    });
  }

  for (final locale in ['ru', 'en']) {
    testWidgets('320px, $locale, text scale 2: доступное Меню без overflow', (
      tester,
    ) async {
      // AC:RL-support-menu-navigation/20
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (_, controller) = await _setup(tester);
      String? fontFamily;
      final out = Platform.environment['SUPPORT_MENU_VISUAL_DIR'];
      if (out != null) {
        const path = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
        final loader = FontLoader('SupportVisual')
          ..addFont(
            Future.value(File(path).readAsBytesSync().buffer.asByteData()),
          );
        await tester.runAsync(loader.load);
        fontFamily = 'SupportVisual';
      }
      await _mount(
        tester,
        controller,
        locale: locale,
        scale: 2,
        fontFamily: fontFamily,
      );
      final menu = find.widgetWithText(
        TextButton,
        locale == 'ru' ? 'Меню' : 'Menu',
      );
      final semantics = tester.ensureSemantics();
      expect(menu, findsOneWidget);
      expect(
        tester.getSemantics(menu),
        matchesSemantics(
          label: locale == 'ru' ? 'Меню' : 'Menu',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(tester.getRect(menu).right, lessThanOrEqualTo(320));
      expect(tester.getRect(menu).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      semantics.dispose();
      if (out != null && locale == 'ru') {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('support-composer-image')),
        );
        final image = (await tester.runAsync(boundary.toImage))!;
        final bytes = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        );
        File(
          '$out/composer-320-ru-scale2.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      }
      await tester.pump(const Duration(milliseconds: 100));
    });
  }
}
