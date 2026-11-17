// ledger:RL-receipts-list-lazy-member
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/seen_by_receipts_sheet.dart';
import 'package:liza/utils/room_status_extension.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/mxc_image.dart';

import '../../../utils/test_client.dart';

const _lena = '@elena:example.invalid';
final _avatar = Uri.parse('mxc://example.invalid/lena');
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _MatrixState extends liza_matrix.MatrixState {
  _MatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
  @override
  bool isAiUser(String userId) => userId == '@ai:example.invalid';
}

// Управляется HTTP-граница SDK, а не resolver/виджет. Частично загруженная
// комната и реальная SQLite проверяются отдельно основным SDK-тестом.
class _MemberApi extends FakeMatrixApi {
  _Room? activeRoom;
  var profileCalls = 0;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final room = activeRoom;
    final segments = request.url.pathSegments;
    if (room != null && segments.contains('m.room.member')) {
      final id = segments.last;
      room.calls.update(id, (n) => n + 1, ifAbsent: () => 1);
      final user = await (room.pending[id] ??= Completer<User?>()).future;
      if (user == null) {
        return http.Response(
          '{"errcode":"M_NOT_FOUND","error":"missing"}',
          404,
        );
      }
      return http.Response(
        jsonEncode({
          'membership': user.membership.name,
          'displayname': user.displayName,
          if (user.avatarUrl != null) 'avatar_url': user.avatarUrl.toString(),
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (room != null && segments.contains('profile')) {
      profileCalls++;
      return http.Response('{"errcode":"M_NOT_FOUND","error":"missing"}', 404);
    }
    final response = await super.mockIntercept(request);
    return http.Response.bytes(
      response.bodyBytes,
      response.statusCode,
      headers: {
        ...response.headers,
        'content-type': 'application/json; charset=utf-8',
      },
    );
  }
}

class _Room extends Room {
  _Room(Client client, {super.id = '!controlled:example.invalid'})
    : super(client: client) {
    partial = false;
  }
  final calls = <String, int>{};
  final pending = <String, Completer<User?>>{};
}

User _member(Room room, String id, String name, {Uri? avatar}) => User(
  id,
  room: room,
  displayName: name,
  membership: 'join',
  avatarUrl: avatar?.toString(),
);

void main() {
  late Client client;
  late _MemberApi api;

  Future<void> disposeClient(WidgetTester tester, Client target) async {
    await tester.runAsync(() async {
      // dispose ждёт транзакцию, но sync может ещё загружать данные до неё.
      // Останавливаем новые циклы и дожидаемся всего текущего sync до БД.
      target.backgroundSync = false;
      await target.oneShotSync();
      await target.dispose();
    });
  }

  Future<void> init(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      api = _MemberApi();
      client = await prepareTestClient(loggedIn: true, httpClient: api);
    });
    addTearDown(() async {
      await disposeClient(tester, client);
      MxcImage.clearImageCache();
    });
  }

  Future<void> settle(WidgetTester tester) async {
    // SQLite → SDK stream → FutureBuilder проходят несколько async-ступеней.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpList(
    WidgetTester tester,
    List<MessageReadReceipt> receipts,
  ) async {
    api.activeRoom = receipts.firstOrNull?.user.room is _Room
        ? receipts.first.user.room as _Room
        : null;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Provider<liza_matrix.MatrixState>.value(
          value: _MatrixState(client),
          child: Scaffold(body: ReadReceiptsList(receipts: receipts)),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await settle(tester);
  }

  void wTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 11));
      }
    });
  }

  wTest('lazy member: SDK state updates real name and decoded photo', (
    tester,
  ) async {
    await init(tester);
    final room = Room(id: '!lazy:example.invalid', client: client);
    final path =
        '/client/v3/rooms/${Uri.encodeComponent(room.id)}'
        '/state/m.room.member/${Uri.encodeComponent(_lena)}';
    FakeMatrixApi.currentApi!.api['GET']![path] = (_) => {
      'membership': 'join',
      'displayname': 'Лена в комнате',
      'avatar_url': _avatar.toString(),
    };
    FakeMatrixApi.calledEndpoints.clear();
    MxcImage.seedImageCache('avatar-crop-v2:${_avatar}_44', _png);
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: room), 1)]);
    await tester.pump();
    await settle(tester);
    expect(find.byType(ListTile), findsOneWidget);
    // AC:RL-receipts-list-lazy-member/1
    expect(
      find.text('Лена в комнате'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' / '),
    );
    expect(tester.widget<Avatar>(find.byType(Avatar)).mxContent, _avatar);
    expect(FakeMatrixApi.calledEndpoints[path], hasLength(1));
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<MemoryImage>());
    final decoded = Completer<ImageInfo>();
    final stream = image.image.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      if (!decoded.isCompleted) decoded.complete(info);
    });
    stream.addListener(listener);
    final info = await tester.runAsync(() => decoded.future);
    stream.removeListener(listener);
    expect(info!.image.width, 1);
    expect(info.image.height, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  });

  wTest('partial room loads stored member without state or profile requests', (
    tester,
  ) async {
    await init(tester);
    final room = Room(id: '!stored:example.invalid', client: client);
    await tester.runAsync(
      () => client.database.storeEventUpdate(
        room.id,
        _member(room, _lena, 'Имя из БД'),
        EventUpdateType.state,
        client,
      ),
    );
    expect(room.getState(EventTypes.RoomMember, _lena), isNull);
    FakeMatrixApi.calledEndpoints.clear();
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: room), 0)]);
    await settle(tester);
    // AC:RL-receipts-list-lazy-member/1
    expect(find.text('Имя из БД'), findsOneWidget);
    expect(
      FakeMatrixApi.calledEndpoints.keys.where(
        (p) => p.contains('/profile/') || p.contains('/state/m.room.member/'),
      ),
      isEmpty,
    );
    expect(room.getState(EventTypes.RoomMember, _lena), isNull);
  });

  wTest('unavailable room member falls back to global SDK profile', (
    tester,
  ) async {
    await init(tester);
    final room = Room(id: '!global:example.invalid', client: client)
      ..partial = false;
    final statePath =
        '/client/v3/rooms/${Uri.encodeComponent(room.id)}'
        '/state/m.room.member/${Uri.encodeComponent(_lena)}';
    final profilePath = '/client/v3/profile/${Uri.encodeComponent(_lena)}';
    api.api['GET']![statePath] = (_) => {
      'errcode': 'M_NOT_FOUND',
      'error': 'no member',
    };
    api.api['GET']![profilePath] = (_) => {'displayname': 'Глобальная Лена'};
    FakeMatrixApi.calledEndpoints.clear();
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: room), 0)]);
    await settle(tester);
    // AC:RL-receipts-list-lazy-member/1
    expect(find.text('Глобальная Лена'), findsOneWidget);
    expect(FakeMatrixApi.calledEndpoints[statePath], hasLength(1));
    expect(FakeMatrixApi.calledEndpoints[profilePath], hasLength(1));
    expect(room.getState(EventTypes.RoomMember, _lena), isNull);
  });

  wTest('existing room member wins over receipt snapshot with zero requests', (
    tester,
  ) async {
    await init(tester);
    final room = _Room(client);
    final stale = _member(room, _lena, 'Старое имя');
    room.setState(_member(room, _lena, 'Комнатное имя'));
    FakeMatrixApi.calledEndpoints.clear();
    await pumpList(tester, [MessageReadReceipt(stale, 0)]);
    // AC:RL-receipts-list-lazy-member/2
    expect(find.text('Комнатное имя'), findsOneWidget);
    expect(find.text('Старое имя'), findsNothing);
    expect(room.calls, isEmpty);
    await settle(tester);
    expect(
      FakeMatrixApi.calledEndpoints.keys.where(
        (p) => p.contains('/profile/') || p.contains('/state/m.room.member/'),
      ),
      isEmpty,
    );
  });

  for (final outcome in ['success', 'null', 'error']) {
    wTest('rebuild and row eviction do not retry $outcome', (tester) async {
      await init(tester);
      final room = _Room(client);
      final receipts = [MessageReadReceipt(User(_lena, room: room), 0)];
      for (var i = 0; i < 80; i++) {
        final user = _member(room, '@reader$i:example.invalid', 'Читатель $i');
        room.setState(user);
        receipts.add(MessageReadReceipt(user, 0));
      }
      await pumpList(tester, receipts);
      expect(room.calls[_lena], 1);
      // AC:RL-receipts-list-lazy-member/1
      expect(find.text('Elena'), findsOneWidget);
      switch (outcome) {
        case 'success':
          room.pending[_lena]!.complete(_member(room, _lena, 'Лена'));
        case 'null':
          room.pending[_lena]!.complete(null);
        case 'error':
          room.pending[_lena]!.completeError(StateError('member unavailable'));
      }
      await settle(tester);
      await pumpList(tester, List.of(receipts));
      final list = find.byType(ListView);
      await tester.drag(list, const Offset(0, -5000));
      await tester.pumpAndSettle();
      expect(
        find
            .byType(Avatar)
            .evaluate()
            .any(
              (e) =>
                  (e.widget as Avatar).name ==
                  (outcome == 'success' ? 'Лена' : 'Elena'),
            ),
        isFalse,
        reason: 'первая строка уничтожена после прокрутки',
      );
      await tester.drag(list, const Offset(0, 5000));
      await tester.pumpAndSettle();
      // AC:RL-receipts-list-lazy-member/3
      expect(room.calls[_lena], 1);
      expect(
        find.text(outcome == 'success' ? 'Лена' : 'Elena'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final outcome in ['null', 'error', 'timeout']) {
    wTest('$outcome keeps fallback and never retries', (tester) async {
      await init(tester);
      final room = _Room(client);
      final receipts = [MessageReadReceipt(User(_lena, room: room), 0)];
      await pumpList(tester, receipts);
      expect(room.calls[_lena], 1);
      if (outcome == 'null') room.pending[_lena]!.complete(null);
      if (outcome == 'error') {
        room.pending[_lena]!.completeError(StateError('offline'));
      }
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Elena'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      if (outcome == 'timeout') {
        room.pending[_lena]!.complete(_member(room, _lena, 'Поздний ответ'));
      }
      await tester.pump();
      await pumpList(tester, receipts);
      // AC:RL-receipts-list-lazy-member/4
      expect(find.text('Elena'), findsOneWidget);
      expect(find.text('Поздний ответ'), findsNothing);
      expect(room.calls[_lena], 1);
      expect(tester.takeException(), isNull);
    });
  }

  wTest(
    'late failed state response after timeout cannot start global profile',
    (tester) async {
      await init(tester);
      final room = _Room(client);
      await pumpList(tester, [MessageReadReceipt(User(_lena, room: room), 0)]);
      expect(room.calls[_lena], 1);
      await tester.pump(const Duration(seconds: 10));
      room.pending[_lena]!.complete(null);
      await settle(tester);
      // AC:RL-receipts-list-lazy-member/4
      expect(find.text('Elena'), findsOneWidget);
      expect(api.profileCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  wTest('invalid MXID never starts member or profile requests', (tester) async {
    await init(tester);
    final room = _Room(client);
    final users = [
      '',
      'elena',
      '@elena',
      '@elena:',
      '@:invalid',
      '!room:example.invalid',
    ];
    await pumpList(tester, [
      for (final id in users) MessageReadReceipt(User(id, room: room), 0),
    ]);
    await tester.pump(const Duration(seconds: 11));
    // AC:RL-receipts-list-lazy-member/4
    expect(find.byType(ListTile), findsNWidgets(users.length));
    expect(room.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final fails in [false, true]) {
    wTest('completion after dispose is safe: error=$fails', (tester) async {
      await init(tester);
      final room = _Room(client);
      await pumpList(tester, [MessageReadReceipt(User(_lena, room: room), 0)]);
      expect(room.calls[_lena], 1);
      await tester.pumpWidget(const SizedBox());
      if (fails) {
        room.pending[_lena]!.completeError(StateError('after dispose'));
      } else {
        room.pending[_lena]!.complete(_member(room, _lena, 'Лена'));
      }
      await tester.pump();
      // AC:RL-receipts-list-lazy-member/4
      expect(find.byType(ReadReceiptsList), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  wTest('same room id uses object identity and ignores out-of-order response', (
    tester,
  ) async {
    await init(tester);
    final old = _Room(client);
    final next = _Room(client);
    expect(
      old,
      next,
      reason: 'SDK Room equality deliberately ignores identity',
    );
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: old), 0)]);
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: next), 0)]);
    expect(old.calls[_lena], 1);
    expect(next.calls[_lena], 1);
    next.pending[_lena]!.complete(_member(next, _lena, 'Новая комната'));
    await settle(tester);
    old.pending[_lena]!.complete(_member(old, _lena, 'Старая комната'));
    await tester.pump();
    // AC:RL-receipts-list-lazy-member/5
    expect(find.text('Новая комната'), findsOneWidget);
    expect(find.text('Старая комната'), findsNothing);
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: old), 0)]);
    await tester.pump();
    expect(find.text('Старая комната'), findsOneWidget);
    expect(old.calls[_lena], 1);
  });

  wTest('same room id across different clients cannot reuse account snapshot', (
    tester,
  ) async {
    await init(tester);
    late Client secondClient;
    await tester.runAsync(() async {
      secondClient = await prepareTestClient(
        httpClient: api,
        loggedIn: true,
        clientName: 'Other account',
      );
    });
    addTearDown(() => disposeClient(tester, secondClient));
    await tester.runAsync(() async {
      const key = 'com.liza.fixture.database_isolation';
      await client.database.storeAccountData(key, {'owner': 'first'});
      expect((await client.database.getAccountData()).containsKey(key), isTrue);
      expect(
        (await secondClient.database.getAccountData()).containsKey(key),
        isFalse,
        reason: 'У разных тестовых аккаунтов должны быть независимые БД',
      );
    });
    final old = _Room(client);
    final next = _Room(secondClient);
    expect(old, next);
    expect(identical(old.client, next.client), isFalse);
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: old), 0)]);
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: next), 0)]);
    next.pending[_lena]!.complete(_member(next, _lena, 'Другой аккаунт'));
    await settle(tester);
    old.pending[_lena]!.complete(_member(old, _lena, 'Первый аккаунт'));
    await settle(tester);
    // AC:RL-receipts-list-lazy-member/5
    expect(find.text('Другой аккаунт'), findsOneWidget);
    expect(find.text('Первый аккаунт'), findsNothing);
    expect(old.calls[_lena], 1);
    expect(next.calls[_lena], 1);
  });

  wTest('changing user ignores previous snapshot and late completion', (
    tester,
  ) async {
    await init(tester);
    final room = _Room(client);
    const other = '@other:example.invalid';
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: room), 0)]);
    await pumpList(tester, [MessageReadReceipt(User(other, room: room), 0)]);
    room.pending[other]!.complete(_member(room, other, 'Другой'));
    await settle(tester);
    room.pending[_lena]!.complete(_member(room, _lena, 'Лена'));
    await tester.pump();
    // AC:RL-receipts-list-lazy-member/5
    expect(find.text('Другой'), findsOneWidget);
    expect(find.text('Лена'), findsNothing);
    expect(room.calls, {_lena: 1, other: 1});
  });

  wTest('member appearing while loading wins over stale response', (
    tester,
  ) async {
    await init(tester);
    final room = _Room(client);
    await pumpList(tester, [MessageReadReceipt(User(_lena, room: room), 0)]);
    MxcImage.seedImageCache('avatar-crop-v2:${_avatar}_44', _png);
    room.setState(_member(room, _lena, 'Актуальный участник', avatar: _avatar));
    room.pending[_lena]!.complete(
      _member(
        room,
        _lena,
        'Устаревший ответ',
        avatar: Uri.parse('mxc://example.invalid/stale'),
      ),
    );
    await settle(tester);
    // AC:RL-receipts-list-lazy-member/5
    expect(find.text('Актуальный участник'), findsOneWidget);
    expect(find.text('Устаревший ответ'), findsNothing);
    expect(tester.widget<Avatar>(find.byType(Avatar)).mxContent, _avatar);
    final current = room.getState(EventTypes.RoomMember, _lena)!.asUser(room);
    expect(current.displayName, 'Актуальный участник');
    expect(current.avatarUrl, _avatar);
  });

  wTest('resolution preserves count, input order, timestamps and AI shape', (
    tester,
  ) async {
    await init(tester);
    final room = _Room(client);
    const ai = '@ai:example.invalid';
    final receipts = [
      MessageReadReceipt(User(_lena, room: room), 0),
      MessageReadReceipt(User(ai, room: room), 60000),
    ];
    await pumpList(tester, receipts);
    final beforeTimes = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.trailing as Text?)?.data)
        .toList();
    room.pending[ai]!.complete(_member(room, ai, 'ИИ'));
    room.pending[_lena]!.complete(_member(room, _lena, 'Лена'));
    await settle(tester);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    // AC:RL-receipts-list-lazy-member/6
    expect(find.text('2'), findsOneWidget);
    expect(tiles.map((t) => (t.title as Text).data), ['Лена', 'ИИ']);
    expect(tiles.map((t) => (t.trailing as Text?)?.data), beforeTimes);
    expect(beforeTimes[0], isNull);
    expect(beforeTimes[1], isNotEmpty);
    expect(
      tester.widgetList<Avatar>(find.byType(Avatar)).map((a) => a.isHexagonal),
      [false, true],
    );
  });

  wTest('receipt calculation has zero member requests across rebuild inputs', (
    tester,
  ) async {
    await init(tester);
    final room = _Room(client);
    final events = [
      for (var i = 0; i < 20; i++)
        Event(
          eventId: '\$event$i',
          senderId: '@reader$i:example.invalid',
          type: EventTypes.Message,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1000 - i),
          content: {'msgtype': 'm.text', 'body': 'message'},
          room: room,
        ),
    ];
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: events, nextBatch: ''),
    );
    FakeMatrixApi.calledEndpoints.clear();
    for (var i = 0; i < 5; i++) {
      // AC:RL-receipts-list-lazy-member/7
      expect(room.getReadReceiptsPerMessage(timeline).length, 20);
    }
    await settle(tester);
    expect(room.calls, isEmpty);
    expect(
      FakeMatrixApi.calledEndpoints.keys.where(
        (p) => p.contains('/profile/') || p.contains('/state/m.room.member/'),
      ),
      isEmpty,
    );
  });
}
