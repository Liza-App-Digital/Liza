// ledger:RL-push-read-banner-sweep
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/android_room_notification.dart';
import 'package:liza/utils/push_client_resolver.dart';

ActiveNotification _ours(int id, String client, String room, String event) =>
    ActiveNotification(id: id, tag: room, payload: '$client|$room|$event');

ActiveNotification _system(String room) => ActiveNotification(id: 0, tag: room);

void main() {
  group('Android: id уведомления = хэш события, тег = комната (Р5)', () {
    test('AC:RL-push-read-banner-sweep/11 id стабилен, зависит от события и '
        'аккаунта, не 0 и не по комнате', () {
      final a = pushEventNotificationId('c1', r'$e1');
      expect(
        pushEventNotificationId('c1', r'$e1'),
        a,
        reason: 'повтор = тот же id',
      );
      expect(pushEventNotificationId('c1', r'$e2'), isNot(a));
      expect(
        pushEventNotificationId('c2', r'$e1'),
        isNot(a),
        reason: 'два своих аккаунта в одной комнате — два уведомления',
      );
      expect(a, isNot(pushNotificationId('c1', '!room')));
      // Значение — sha256, а не String.hashCode: одинаково в любом процессе.
      expect(pushEventNotificationId('c1', r'$e1'), 614104003);
      for (var i = 0; i < 2000; i++) {
        final id = pushEventNotificationId('c', '\$$i');
        expect(id, greaterThan(0));
      }
    });

    test('AC:RL-push-read-banner-sweep/12 новое событие наследует переписку '
        'своего уведомления комнаты (новое или прежней сборки); баннер Play '
        'Services и чужой аккаунт — не переписка', () {
      final own = _ours(77, 'c1', '!a', r'$a1');
      expect(
        androidRoomConversation(
          active: [_system('!a'), _ours(5, 'c2', '!a', r'$x'), own],
          ownClientName: 'c1',
          roomId: '!a',
        ),
        (id: 77, tag: '!a'),
      );
      final legacy = ActiveNotification(
        id: pushNotificationId('c1', '!a'),
        payload: 'c1|!a|\$old',
      );
      expect(
        androidRoomConversation(
          active: [legacy],
          ownClientName: 'c1',
          roomId: '!a',
        ),
        (id: pushNotificationId('c1', '!a'), tag: null),
      );
      expect(
        androidRoomConversation(
          active: [_system('!a'), _ours(5, 'c2', '!a', r'$x'), own],
          ownClientName: 'c1',
          roomId: '!b',
        ),
        isNull,
      );
    });

    test('AC:RL-push-read-banner-sweep/13 снятие комнаты — по тегу и payload, '
        'вместе с баннером Play Services; баннер без владельца — только если '
        'комната не принадлежит другому аккаунту', () {
      final active = [
        _ours(11, 'c1', '!a', r'$a2'),
        _system('!a'),
        _ours(12, 'c1', '!b', r'$b1'),
        _ours(13, 'c2', '!a', r'$a2'),
        ActiveNotification(id: pushNotificationId('c1', '!a')),
      ];
      expect(
        androidRoomNotificationsToCancel(
          active: active,
          ownClientName: 'c1',
          roomId: '!a',
          ownerlessIsOurs: true,
        ),
        [
          (id: 11, tag: '!a'),
          (id: 0, tag: '!a'),
          (id: pushNotificationId('c1', '!a'), tag: null),
        ],
      );
      expect(
        androidRoomNotificationsToCancel(
          active: active,
          ownClientName: 'c1',
          roomId: '!a',
          ownerlessIsOurs: false,
        ),
        [(id: 11, tag: '!a')],
      );
    });

    test('AC:RL-push-read-banner-sweep/13 комната уведомления: payload, тег, '
        'id прежней сборки', () {
      expect(androidNotificationRoom(_ours(1, 'c', '!p', r'$e')), '!p');
      expect(androidNotificationRoom(_system('!t')), '!t');
      expect(
        androidNotificationRoom(
          ActiveNotification(id: '!r'.hashCode),
          ownClientName: 'c',
          roomIds: ['!q', '!r'],
        ),
        '!r',
      );
      expect(
        androidNotificationRoom(
          const ActiveNotification(id: 424242),
          ownClientName: 'c',
          roomIds: ['!q'],
        ),
        isNull,
      );
    });
  });
}
