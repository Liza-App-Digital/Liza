// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liza/utils/stories/stories_extension.dart';

import 'test_client.dart';

Event _seg(Room room, String id, int ts) => Event(
      eventId: id,
      senderId: '@author:example.invalid',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
      type: EventTypes.Message,
      content: const {},
      room: room,
    );

void _setReceipts(Room room, Map<String, Object?> globalJson) {
  room.roomAccountData['com.famedly.receipts_state'] = BasicEvent(
    type: 'com.famedly.receipts_state',
    content: {'global': globalJson},
  );
}

void main() {
  late Client client;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
  });
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  test('myReceiptIndexIn: свой receipt на втором сегменте [ledger:RL-stories-seen-sync]', () {
    final room = Room(id: '!s:example.invalid', client: client);
    final segs = [_seg(room, r'$a', 1), _seg(room, r'$b', 2)];
    _setReceipts(room, {
      'latest': {'e': r'$b', 'ts': 2},
    });
    expect(client.myReceiptIndexIn(room, segs), 1);
  });

  test('myReceiptIndexIn: receipt отсутствует - минус один [ledger:RL-stories-seen-sync]', () {
    final room = Room(id: '!s2:example.invalid', client: client);
    final segs = [_seg(room, r'$a', 1)];
    expect(client.myReceiptIndexIn(room, segs), -1);
  });

  test(
    'viewerReceiptEventIds: последний receipt зрителя, максимум из global и main [ledger:RL-stories-seen-sync]',
    () {
      final room = Room(id: '!s3:example.invalid', client: client);
      room.roomAccountData['com.famedly.receipts_state'] = BasicEvent(
        type: 'com.famedly.receipts_state',
        content: {
          'global': {
            'others': {
              '@v1:x': {'e': r'$a', 'ts': 1},
              '@v2:x': {'e': r'$b', 'ts': 5},
            },
          },
          'main': {
            'others': {
              '@v1:x': {'e': r'$c', 'ts': 3},
              '@v2:x': {'e': r'$old', 'ts': 2},
            },
          },
        },
      );
      final map = client.viewerReceiptEventIds(room);
      expect(map, {'@v1:x': r'$c', '@v2:x': r'$b'});
    },
  );
}
