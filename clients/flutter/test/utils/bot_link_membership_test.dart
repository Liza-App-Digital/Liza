// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-deep-links AC:RL-bot-deep-links/8
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/bot_link_membership.dart';
import 'test_client.dart';

class _MembershipApi extends FakeMatrixApi {
  FutureOr<http.Response> Function()? readMember;
  var reads = 0;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) {
    if (readMember != null &&
        request.url.path.contains('/state/m.room.member/')) {
      reads++;
      return readMember!();
    }
    return super.mockIntercept(request);
  }
}

void main() {
  late _MembershipApi api;
  late Client client;
  const room = '!named:example.test';
  const bot = '@lazybot:example.test';
  http.Response member(String value) => http.Response(
    jsonEncode({'membership': value}),
    200,
    headers: {'content-type': 'application/json'},
  );
  setUp(() async {
    api = _MembershipApi();
    client = await prepareTestClient(loggedIn: true, httpClient: api);
  });
  tearDown(() => client.dispose());

  test(
    'fresh join разрешён без локального membership и дополнительного sync',
    () async {
      expect(
        client.getRoomById(room)?.getState(EventTypes.RoomMember, bot),
        isNull,
      );
      api.readMember = () => member('join');
      expect(
        await waitForBotLinkMembership(
          client,
          room,
          bot,
          isCurrent: () => true,
        ),
        isTrue,
      );
      expect(api.reads, 1);
    },
  );

  test('актуальные leave/ban не дают команду запуска', () async {
    for (final status in ['leave', 'ban']) {
      api.readMember = () => member(status);
      expect(
        await waitForBotLinkMembership(
          client,
          room,
          bot,
          isCurrent: () => true,
        ),
        isFalse,
      );
    }
  });

  test(
    'смена маршрута/аккаунта во время GET не разрешает поздний join',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      var current = true;
      api.readMember = () {
        started.complete();
        return response.future;
      };
      final pending = waitForBotLinkMembership(
        client,
        room,
        bot,
        isCurrent: () => current,
      );
      await started.future;
      current = false;
      response.complete(member('join'));
      expect(await pending, isFalse);
    },
  );

  test(
    'пустой бюджет не делает HTTP, зависший GET ограничен бюджетом',
    () async {
      api.readMember = () => Completer<http.Response>().future;
      expect(
        await waitForBotLinkMembership(
          client,
          room,
          bot,
          isCurrent: () => true,
          timeout: Duration.zero,
        ),
        isFalse,
      );
      expect(api.reads, 0);
      expect(
        await waitForBotLinkMembership(
          client,
          room,
          bot,
          isCurrent: () => true,
          timeout: const Duration(milliseconds: 20),
        ),
        isFalse,
      );
      expect(api.reads, 1);
    },
  );

  test('invite и временный404 проверяются повторно по свежему HTTP', () async {
    var call = 0;
    api.readMember = () => switch (call++) {
      0 => http.Response('{"errcode":"M_NOT_FOUND","error":"not yet"}', 404),
      1 => member('invite'),
      _ => member('join'),
    };
    expect(
      await waitForBotLinkMembership(client, room, bot, isCurrent: () => true),
      isTrue,
    );
    expect(api.reads, 3);
  });
}
