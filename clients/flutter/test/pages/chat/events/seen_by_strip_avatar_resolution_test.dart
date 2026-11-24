// ledger:RL-seen-by-strip-avatar-resolution
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/utils/avatar_stats.dart';
import 'package:liza/utils/room_status_extension.dart';
import 'package:liza/utils/reader_profile_resolver.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/mxc_image.dart';

import '../../../utils/test_client.dart';

// Два разных 1x1 PNG: по байтам видно, чья именно аватарка нарисована.
final _white = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);
final _red = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
);

String _id(String name) => '@$name:example.invalid';
Uri _mxc(String name) => Uri.parse('mxc://example.invalid/$name');

class _MatrixState extends liza_matrix.MatrixState {
  _MatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
  @override
  bool isAiUser(String userId) => false;
}

enum _Reply { ok, notFound, forbidden, hang }

/// Граница HTTP: считает запросы /profile/ по MXID и отвечает по сценарию.
class _ProfileApi extends FakeMatrixApi {
  final replies = <String, _Reply>{};
  final avatarOverride = <String, String>{};
  final recheckAges = <String>[];
  final calls = <String, int>{};
  final hung = <Completer<void>>[];
  var stateMemberCalls = 0;

  int get totalProfileCalls => calls.values.fold(0, (a, b) => a + b);

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final segments = request.url.pathSegments;
    if (segments.contains('profile')) {
      final id = Uri.decodeComponent(segments.last);
      calls.update(id, (n) => n + 1, ifAbsent: () => 1);
      final reply = replies[id] ?? _Reply.notFound;
      switch (reply) {
        case _Reply.hang:
          final gate = Completer<void>();
          hung.add(gate);
          await gate.future;
          return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
        case _Reply.notFound:
          return http.Response(
            '{"errcode":"M_NOT_FOUND","error":"missing"}',
            404,
          );
        case _Reply.forbidden:
          return http.Response(
            '{"errcode":"M_FORBIDDEN","error":"forbidden"}',
            403,
          );
        case _Reply.ok:
          final name = id.substring(1, id.indexOf(':'));
          return http.Response(
            jsonEncode({
              'displayname': 'Имя $name',
              'avatar_url': _mxc(avatarOverride[id] ?? name).toString(),
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
      }
    }
    if (segments.contains('m.room.member')) stateMemberCalls++;
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

void main() {
  late Client client;
  late _ProfileApi api;

  Future<void> init(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      api = _ProfileApi();
      client = await prepareTestClient(loggedIn: true, httpClient: api);
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        client.backgroundSync = false;
        await client.oneShotSync();
        await client.dispose();
      });
      MxcImage.clearImageCache();
      AvatarStats.instance.takeSnapshot();
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Room roomOf(String suffix) =>
      Room(id: '!$suffix:example.invalid', client: client)..partial = false;

  void putMember(Room room, String name) {
    // Кладём напрямую: setState шлёт onRoomState, чьи подписчики заводят таймеры.
    (room.states[EventTypes.RoomMember] ??= {})[_id(name)] = Event(
      type: EventTypes.RoomMember,
      stateKey: _id(name),
      senderId: _id(name),
      eventId: '\$member-$name-${room.id}',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
      room: room,
      content: {
        'membership': 'join',
        'displayname': 'Состав $name',
        'avatar_url': _mxc('state-$name').toString(),
      },
    );
  }

  List<MessageReadReceipt> receiptsOf(Room room, List<String> names) => [
    for (var i = 0; i < names.length; i++)
      MessageReadReceipt(
        room.getState(EventTypes.RoomMember, _id(names[i]))?.asUser(room) ??
            User(_id(names[i]), room: room),
        i + 1,
      ),
  ];

  Future<void> pumpStrip(
    WidgetTester tester,
    List<List<MessageReadReceipt>> strips, {
    int generation = 0,
    bool settleAfter = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        key: ValueKey(generation),
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Provider<liza_matrix.MatrixState>.value(
          value: _MatrixState(client),
          child: Scaffold(
            body: Column(
              children: [for (final s in strips) SeenByAvatars(receipts: s)],
            ),
          ),
        ),
      ),
    );
    if (settleAfter) await settle(tester);
  }

  // Картинка аватарки i-го читателя: именно Image внутри его Avatar.
  MemoryImage? photoOf(WidgetTester tester, String userName) {
    final avatars = find.byWidgetPredicate(
      (w) => w is Avatar && w.name == 'Имя $userName',
    );
    if (avatars.evaluate().isEmpty) return null;
    final images = find.descendant(
      of: avatars.first,
      matching: find.byType(Image),
    );
    if (images.evaluate().isEmpty) return null;
    final provider = tester.widget<Image>(images.first).image;
    return provider is MemoryImage ? provider : null;
  }

  void seed(String name, Uint8List bytes) =>
      MxcImage.seedImageCache('avatar-crop-v2:${_mxc(name)}_16', bytes);

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

  wTest(
    'AC-1: читатель в room state — аватарка из member-события, 0 запросов',
    (tester) async {
      await init(tester);
      final room = roomOf('instate');
      putMember(room, 'anna');
      seed('state-anna', _white);
      await pumpStrip(tester, [
        receiptsOf(room, ['anna']),
      ]);
      // AC:RL-seen-by-strip-avatar-resolution/1
      expect(api.totalProfileCalls, 0);
      final avatar = tester.widget<Avatar>(find.byType(Avatar));
      expect(avatar.mxContent, _mxc('state-anna'));
    },
  );

  wTest(
    'AC-3: вне state с профилем — буква до ответа, фото того же читателя после',
    (tester) async {
      await init(tester);
      final room = roomOf('outstate');
      api.replies[_id('boris')] = _Reply.ok;
      api.replies[_id('vera')] = _Reply.ok;
      api.replies[_id('gleb')] = _Reply.ok;
      seed('boris', _white);
      seed('vera', _red);
      seed('gleb', _white);
      await pumpStrip(tester, [
        receiptsOf(room, ['boris', 'vera', 'gleb']),
      ], settleAfter: false);
      // Локализации грузятся асинхронно; HTTP-ответы без runAsync не приходят —
      // кадр после загрузки показывает именно состояние «профили ещё не пришли».
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(Avatar), findsNWidgets(3));
      expect(find.byType(Image), findsNothing);
      final sizeBefore = tester.getSize(find.byType(SeenByAvatars));
      await settle(tester);
      // AC:RL-seen-by-strip-avatar-resolution/3
      expect(api.calls[_id('boris')], 1);
      expect(photoOf(tester, 'boris')?.bytes, _white);
      expect(photoOf(tester, 'vera')?.bytes, _red);
      expect(photoOf(tester, 'gleb')?.bytes, _white);
      expect(
        tester.widgetList<Avatar>(find.byType(Avatar)).map((a) => a.client),
        everyElement(same(client)),
      );
      // AC:RL-seen-by-strip-avatar-resolution/11
      expect(tester.getSize(find.byType(SeenByAvatars)), sizeBefore);
      // AC:RL-seen-by-strip-avatar-resolution/9
      expect(room.getState(EventTypes.RoomMember, _id('boris')), isNull);
      expect(api.stateMemberCalls, 0);
    },
  );

  wTest('AC-4: 404 и 403 — буква, rebuild не повторяет запрос', (tester) async {
    await init(tester);
    final room = roomOf('negative');
    api.replies[_id('dina')] = _Reply.notFound;
    api.replies[_id('egor')] = _Reply.forbidden;
    api.replies[_id('fedor')] = _Reply.notFound;
    final strip = receiptsOf(room, ['dina', 'egor', 'fedor']);
    await pumpStrip(tester, [strip]);
    for (var i = 1; i <= 3; i++) {
      await pumpStrip(tester, [strip], generation: i);
    }
    // AC:RL-seen-by-strip-avatar-resolution/4
    expect(api.calls[_id('dina')], 1);
    expect(api.calls[_id('egor')], 1);
    expect(api.calls[_id('fedor')], 1);
    expect(find.byType(Image), findsNothing);
    expect(find.text('Д'), findsNothing, reason: 'имя по MXID без профиля');
    expect(tester.widgetList<Avatar>(find.byType(Avatar)), hasLength(3));
    expect(
      tester.widgetList<Avatar>(find.byType(Avatar)).map((a) => a.mxContent),
      everyElement(isNull),
    );
  });

  wTest('AC-4: невалидный MXID — буква без запроса в сеть', (tester) async {
    await init(tester);
    final room = roomOf('invalid');
    await pumpStrip(tester, [
      [
        MessageReadReceipt(User('not-an-mxid', room: room), 1),
        MessageReadReceipt(User('@:example.invalid', room: room), 2),
        MessageReadReceipt(User('', room: room), 3),
      ],
    ]);
    expect(api.totalProfileCalls, 0);
    expect(tester.widgetList<Avatar>(find.byType(Avatar)), hasLength(3));
  });

  wTest(
    'AC-5: зависший профиль — буква, таймаут 10 с, поздний ответ не рисуется',
    (tester) async {
      await init(tester);
      final room = roomOf('timeout');
      api.replies[_id('hana')] = _Reply.hang;
      api.replies[_id('igor')] = _Reply.hang;
      api.replies[_id('jana')] = _Reply.hang;
      await pumpStrip(tester, [
        receiptsOf(room, ['hana', 'igor', 'jana']),
      ]);
      expect(tester.widgetList<Avatar>(find.byType(Avatar)), hasLength(3));
      await tester.pump(const Duration(seconds: 11));
      await settle(tester);
      // AC:RL-seen-by-strip-avatar-resolution/5
      expect(find.byType(Image), findsNothing);
      expect(api.calls[_id('hana')], 1, reason: 'повтор — не раньше 30 с');
      for (final gate in api.hung) {
        if (!gate.isCompleted) gate.complete();
      }
      await settle(tester);
      expect(find.byType(Image), findsNothing);
      expect(
        tester.widgetList<Avatar>(find.byType(Avatar)).map((a) => a.mxContent),
        everyElement(isNull),
      );
    },
  );

  wTest('AC-7: один читатель в 3 комнатах — один запрос профиля', (
    tester,
  ) async {
    await init(tester);
    api.replies[_id('kira')] = _Reply.ok;
    seed('kira', _red);
    final rooms = [roomOf('r1'), roomOf('r2'), roomOf('r3')];
    await pumpStrip(tester, [
      for (final r in rooms) receiptsOf(r, ['kira']),
    ]);
    // AC:RL-seen-by-strip-avatar-resolution/7
    expect(api.calls[_id('kira')], 1);
    expect(find.byType(Avatar), findsNWidgets(3));
    expect(photoOf(tester, 'kira')?.bytes, _red);
  });

  wTest('AC-8: 12 читателей вне state — не больше 10 запросов, повторов нет', (
    tester,
  ) async {
    await init(tester);
    final room = roomOf('many');
    final names = [for (var i = 0; i < 12; i++) 'reader$i'];
    for (final n in names) {
      api.replies[_id(n)] = _Reply.ok;
      seed(n, _white);
    }
    final strip = receiptsOf(room, names);
    await pumpStrip(tester, [strip]);
    for (var i = 1; i <= 3; i++) {
      await pumpStrip(tester, [strip], generation: i);
    }
    // AC:RL-seen-by-strip-avatar-resolution/8
    expect(api.totalProfileCalls, lessThanOrEqualTo(10));
    expect(api.calls.values, everyElement(1));
    expect(find.text('+2'), findsOneWidget);
  });

  wTest(
    'AC-6: профиль пришёл позже — аватарка обновляется без пересборки полоски',
    (tester) async {
      await init(tester);
      final room = roomOf('late');
      api.replies[_id('lena')] = _Reply.ok;
      seed('lena', _red);
      await pumpStrip(tester, [
        receiptsOf(room, ['lena']),
      ]);
      // AC:RL-seen-by-strip-avatar-resolution/6
      expect(photoOf(tester, 'lena')?.bytes, _red);
      // Сигнал SDK «профиль изменился» → резолвер перечитывает без участия виджета.
      api.replies[_id('lena')] = _Reply.ok;
      seed('lena', _red);
      final resolver = ReaderProfileResolver.of(client);
      expect(resolver.watch(_id('lena')).value?.avatarUrl, _mxc('lena'));
    },
  );

  wTest(
    'AC-6: смена аватарки (onUserProfileUpdate) — меняется наблюдаемый Image',
    (tester) async {
      await init(tester);
      final room = roomOf('changed');
      api.replies[_id('lena')] = _Reply.ok;
      seed('lena', _white);
      seed('lena-new', _red);
      await pumpStrip(tester, [
        receiptsOf(room, ['lena']),
      ]);
      // AC:RL-seen-by-strip-avatar-resolution/6
      expect(photoOf(tester, 'lena')?.bytes, _white);
      api.avatarOverride[_id('lena')] = 'lena-new';
      // Как в SDK при member-событии: профиль помечается устаревшим, затем сигнал.
      await tester.runAsync(
        () => client.database.markUserProfileAsOutdated(_id('lena')),
      );
      client.onUserProfileUpdate.add(_id('lena'));
      await settle(tester);
      expect(photoOf(tester, 'lena')?.bytes, _red);
      expect(api.calls[_id('lena')], 2);
    },
  );

  wTest('AC-15: читательская аватарка рисует букву, пока миниатюра грузится', (
    tester,
  ) async {
    await init(tester);
    final room = roomOf('loading');
    putMember(room, 'mira');
    seed('state-mira', _white);
    await pumpStrip(tester, [
      receiptsOf(room, ['mira']),
    ]);
    // AC:RL-seen-by-strip-avatar-resolution/15
    final avatars = tester.widgetList<Avatar>(find.byType(Avatar));
    expect(avatars, isNotEmpty);
    expect(avatars.every((a) => a.letterWhileLoading), isTrue);
  });

  wTest('AC-16: счётчик монтирований; читатель в state не ходит в сеть', (
    tester,
  ) async {
    await init(tester);
    final room = roomOf('count');
    putMember(room, 'anna');
    putMember(room, 'boris');
    seed('state-anna', _white);
    seed('state-boris', _red);
    await pumpStrip(tester, [
      receiptsOf(room, ['anna', 'boris']),
    ]);
    // AC:RL-seen-by-strip-avatar-resolution/16
    expect(AvatarStats.instance.eventCount(AvatarEvent.mounted), 2);
    expect(api.totalProfileCalls, 0);
  });
}
