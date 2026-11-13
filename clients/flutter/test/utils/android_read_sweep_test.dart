// ledger:RL-push-read-banner-sweep
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as matrix;

import 'package:liza/utils/android_read_sweep.dart';

matrix.Notification _n(String room, String event, {required bool read}) =>
    matrix.Notification.fromJson({
      'actions': ['notify'],
      'event': {
        'event_id': event,
        'room_id': room,
        'sender': '@a:x',
        'type': 'm.room.message',
        'origin_server_ts': 1,
        'content': {'body': 'hi', 'msgtype': 'm.text'},
      },
      'read': read,
      'room_id': room,
      'ts': 1,
    });

ActiveNotification _local(int id, String client, String room, String event) =>
    ActiveNotification(id: id, payload: '$client|$room|$event');

ActiveNotification _system(String room) => ActiveNotification(id: 0, tag: room);

void main() {
  group('Android: снятие прочитанного на другом устройстве', () {
    test('AC:RL-push-read-banner-sweep/7 свой баннер снимается по прочитанному '
        'событию, непрочитанный остаётся', () {
      final result = androidBannersToCancel(
        active: [_local(1, 'c1', '!a', r'$a1'), _local(2, 'c1', '!b', r'$b1')],
        server: [_n('!b', r'$b1', read: false), _n('!a', r'$a1', read: true)],
        ownClientName: 'c1',
        clientCount: 1,
      );
      expect(result, [(id: 1, tag: null)]);
    });

    test('AC:RL-push-read-banner-sweep/7 баннер Play Services (только тег) '
        'снимается, когда прочитано САМОЕ СВЕЖЕЕ событие комнаты', () {
      final read = androidBannersToCancel(
        active: [_system('!a')],
        server: [_n('!a', r'$a2', read: true), _n('!a', r'$a1', read: true)],
        ownClientName: 'c1',
        clientCount: 1,
      );
      expect(read, [(id: 0, tag: '!a')]);
      // Свежее не прочитано (старое прочитано) — баннер этого сообщения
      // висит законно.
      final fresh = androidBannersToCancel(
        active: [_system('!a')],
        server: [_n('!a', r'$a2', read: false), _n('!a', r'$a1', read: true)],
        ownClientName: 'c1',
        clientCount: 1,
      );
      expect(fresh, isEmpty);
    });

    test('AC:RL-push-read-banner-sweep/8 комнату текущего пуша, чужой аккаунт '
        'и баннер без владельца при мультиаккаунте не трогаем', () {
      final server = [
        _n('!a', r'$a1', read: true),
        _n('!b', r'$b1', read: true),
      ];
      expect(
        androidBannersToCancel(
          active: [_system('!a')],
          server: server,
          ownClientName: 'c1',
          clientCount: 1,
          currentRoomId: '!a',
        ),
        isEmpty,
      );
      expect(
        androidBannersToCancel(
          active: [_local(5, 'c2', '!b', r'$b1'), _system('!a')],
          server: server,
          ownClientName: 'c1',
          clientCount: 2,
        ),
        isEmpty,
      );
    });

    test('AC:RL-push-read-banner-sweep/14 мультиаккаунт: баннер без владельца '
        'снимается, когда его комната не принадлежит другому аккаунту; общая '
        'комната или неизвестные комнаты соседа — не трогаем', () {
      final server = [_n('!a', r'$a1', read: true)];
      expect(
        androidBannersToCancel(
          active: [_system('!a')],
          server: server,
          ownClientName: 'c1',
          clientCount: 2,
          foreignRoomIds: {'!other'},
        ),
        [(id: 0, tag: '!a')],
      );
      expect(
        androidBannersToCancel(
          active: [_system('!a')],
          server: server,
          ownClientName: 'c1',
          clientCount: 2,
          foreignRoomIds: {'!a'},
        ),
        isEmpty,
      );
      expect(
        androidBannersToCancel(
          active: [_system('!a')],
          server: server,
          ownClientName: 'c1',
          clientCount: 2,
        ),
        isEmpty,
      );
    });

    test('AC:RL-push-read-banner-sweep/11 наш баннер с id по событию и тегом '
        'комнаты снимается по прочитанному событию из payload', () {
      final result = androidBannersToCancel(
        active: [
          ActiveNotification(id: 99, tag: '!a', payload: r'c1|!a|$a2'),
          ActiveNotification(id: 98, tag: '!b', payload: r'c1|!b|$b1'),
        ],
        server: [_n('!b', r'$b1', read: false), _n('!a', r'$a2', read: true)],
        ownClientName: 'c1',
        clientCount: 1,
      );
      expect(result, [(id: 99, tag: '!a')]);
    });

    test(
      'AC:RL-push-read-banner-sweep/8 нет прочитанных в ответе — ничего',
      () {
        expect(
          androidBannersToCancel(
            active: [_local(1, 'c1', '!a', r'$a1')],
            server: [_n('!a', r'$a1', read: false)],
            ownClientName: 'c1',
            clientCount: 1,
          ),
          isEmpty,
        );
      },
    );
  });
}
