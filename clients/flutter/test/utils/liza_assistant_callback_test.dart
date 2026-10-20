// ledger:RL-botfather-agent-connect-entry
// AC:RL-botfather-agent-connect-entry/2 AC:RL-botfather-agent-connect-entry/3
//
// Кнопка «Подключить ИИ-агента» стартового меню BotFather: реальный
// `openChatFromCard` (ветка open_chat карточки) → `openLizaAssistantWithCallback`
// на живом Client + FakeMatrixApi. Кнопка — в том виде, в каком её шлёт сервер
// (`MiniAppManager.send_welcome`). Считаем реальные PUT /send и POST /createRoom.
//
// Red-proof:
//   RP-1 (AC-2): в openChatFromCard выключить ветку `callback != null` →
//     agent.start не уходит, 3 кейса AC-2 красные (проверено 2026-10-19).
//   RP-2 (AC-3): для Лизы без callback звать client.ensureDirectChat вместо
//     ensureLizaAssistantDm → мимо основного чата, AC-3 красный (проверено).
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/mini_app_choice_content.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/widgets/matrix.dart';
import 'test_client.dart';

/// Кнопка карточки ровно как в `botfather/miniapp.py::send_welcome`.
Map<String, Object?> _serverButton({String? callback = 'agent.start'}) =>
    jsonDecode(
          jsonEncode({
            'button_id': 'bf.agent',
            'text': 'Подключить ИИ-агента',
            'action': 'open_chat',
            'mxid': MatrixState.lizaMxid,
            if (callback != null) 'callback': callback,
          }),
        )
        as Map<String, Object?>;

void main() {
  late Client client;
  late FakeMatrixApi api;
  late List<Map<String, Object?>> createBodies;
  final liza = MatrixState.lizaMxid;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    client.rooms.clear();
    FakeMatrixApi.client = client;
    api = (client.httpClient as dynamic).inner as FakeMatrixApi;
    FakeMatrixApi.calledEndpoints.clear();
    api.api['PUT'] = _AnySendOk(api.api['PUT']!);
    createBodies = [];
    var n = 0;
    api.api['POST']!['/client/v3/createRoom'] = (data) {
      createBodies.add(
        Map<String, Object?>.from(
          (data is String ? jsonDecode(data) : data) as Map,
        ),
      );
      final room = Room(id: '!created${n++}:example.invalid', client: client);
      _setState(room, EventTypes.RoomMember, liza, {'membership': 'join'});
      client.rooms = [...client.rooms, room];
      return {'room_id': room.id};
    };
  });

  tearDown(() => client.dispose(closeDatabase: true));

  /// Отправленные callback-события: room_id → тела.
  Map<String, List<Map<String, Object?>>> sentCallbacks() {
    final out = <String, List<Map<String, Object?>>>{};
    final re = RegExp(r'^/client/v3/rooms/([^/]+)/send/m\.room\.message/');
    for (final e in FakeMatrixApi.calledEndpoints.entries) {
      final m = re.firstMatch(e.key);
      if (m == null) continue;
      for (final raw in e.value) {
        final body = Map<String, Object?>.from(
          (raw is String ? jsonDecode(raw) : raw) as Map,
        );
        if (body['msgtype'] != MiniAppChoiceContent.callbackMsgType) continue;
        out.putIfAbsent(Uri.decodeComponent(m.group(1)!), () => []).add(body);
      }
    }
    return out;
  }

  /// Тап по кнопке: реальный разбор полей карточки → openChatFromCard.
  /// Возвращает маршрут, на который ушёл go_router.
  Future<String> tap(WidgetTester tester, Map<String, Object?> button) async {
    late BuildContext ctx;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (c, _) => Builder(
            builder: (c) {
              ctx = c;
              return const Scaffold(body: Text('botfather'));
            },
          ),
        ),
        GoRoute(
          path: '/rooms/:roomid',
          builder: (_, s) => Scaffold(body: Text(s.pathParameters['roomid']!)),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
    var done = false;
    Object? error;
    openChatFromCard(
      ctx,
      client,
      mxid: button['mxid'] as String,
      callback: button['callback'] as String?,
      body: button['text'] as String,
    ).then((_) => done = true, onError: (Object e) => error = e);
    // Пауза showFutureLoadingDialog, диалог и БД клиента (sqflite) — реальное
    // время вперемешку с кадрами.
    for (var i = 0; i < 40 && !done && error == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(error, isNull);
    expect(done, isTrue, reason: 'openChatFromCard не завершился');
    await tester.pumpAndSettle();
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'снекбар = отправка callback упала',
    );
    return router.routerDelegate.currentConfiguration.uri.toString();
  }

  group('AC-2: ровно один agent.start в ОСНОВНОЙ чат с Лизой', () {
    testWidgets('основной DM уже есть', (tester) async {
      final main = _dm(client, '!main:x', liza);
      final route = await tap(tester, _serverButton());

      expect(sentCallbacks(), {
        main.id: [
          {
            'msgtype': MiniAppChoiceContent.callbackMsgType,
            'body': 'Подключить ИИ-агента',
            'button_id': 'agent.start',
          },
        ],
      });
      expect(createBodies, isEmpty);
      expect(route, '/rooms/${main.id}');
    });

    testWidgets('DM нет — создаётся, callback уходит в него', (tester) async {
      final route = await tap(tester, _serverButton());

      expect(createBodies.length, 1);
      const created = '!created0:example.invalid';
      expect(sentCallbacks().keys, [created]);
      expect(sentCallbacks()[created]!.single['button_id'], 'agent.start');
      expect(route, '/rooms/$created');
    });

    testWidgets('есть более свежий чат-запрос — выбран основной', (
      tester,
    ) async {
      final main = _dm(client, '!main:x', liza);
      final request = _dm(client, '!req:x', liza, request: true);
      client.accountData['m.direct'] = BasicEvent(
        type: 'm.direct',
        // Без lastEvent SDK при равенстве берёт первый из m.direct — запрос.
        content: {
          liza: [request.id, main.id],
        },
      );
      expect(
        client.getDirectChatFromUserId(liza),
        request.id,
        reason: 'SDK отдал бы запрос — ровно этот случай и закрываем',
      );

      final route = await tap(tester, _serverButton());

      expect(sentCallbacks().keys, [main.id]);
      expect(sentCallbacks()[main.id]!.length, 1);
      expect(createBodies, isEmpty);
      expect(route, '/rooms/${main.id}');
    });
  });

  group('AC-3: только переход в основной чат, события нет', () {
    for (final (name, callback) in [
      ('open_chat без callback', null),
      // Чужой бот прислал кнопку на Лизу с произвольным button_id её мастера.
      ('callback вне lizaCardCallbacks', 'agent.pin.yes'),
    ]) {
      testWidgets(name, (tester) async {
        final main = _dm(client, '!main:x', liza);
        _dm(client, '!req:x', liza, request: true);
        final route = await tap(tester, _serverButton(callback: callback));

        expect(sentCallbacks(), isEmpty);
        expect(createBodies, isEmpty);
        expect(route, '/rooms/${main.id}');
      });
    }
  });
}

/// FakeMatrixApi знает PUT /send только для своих комнат и txnId — отвечаем
/// успехом на любой m.room.message, остальное — как было.
class _AnySendOk extends MapBase<String, dynamic> {
  _AnySendOk(this._inner);

  final Map<String, dynamic> _inner;
  var _n = 0;

  @override
  dynamic operator [](Object? key) =>
      _inner[key] ??
      (key is String && key.contains('/send/m.room.message/')
          ? (_) => {'event_id': '\$sent${_n++}'}
          : null);

  @override
  void operator []=(String key, dynamic value) => _inner[key] = value;

  @override
  void clear() => _inner.clear();

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  dynamic remove(Object? key) => _inner.remove(key);
}

void _setState(
  Room room,
  String type,
  String stateKey,
  Map<String, Object?> content,
) {
  room.setState(
    Event(
      type: type,
      eventId: '\$${room.id}-$type-$stateKey',
      senderId: '@test:fakeServer.notExisting',
      originServerTs: DateTime.now(),
      room: room,
      content: content,
      stateKey: stateKey,
    ),
  );
}

Room _dm(Client client, String id, String liza, {bool request = false}) {
  final room = Room(id: id, client: client);
  if (request) {
    _setState(room, EventTypes.RoomName, '', {'name': 'Лиза: план'});
    _setState(room, lizaRequestStateType, '', {'placeholder': 'Новый запрос'});
  }
  _setState(room, EventTypes.RoomMember, liza, {'membership': 'join'});
  client.rooms.add(room);
  return room;
}
