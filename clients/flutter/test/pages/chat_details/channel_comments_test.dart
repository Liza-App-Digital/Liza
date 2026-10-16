// ledger:RL-channel-discussion-restricted-join
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat_details/chat_details.dart';
import 'package:liza/utils/channel_discussion.dart';

// Привязанный чат должен создаваться с приватностью КАНАЛА, а не всегда
// privateChat: иначе подписчики открытого канала не видят комментариев
// (см. docs/superpowers/specs/2026-07-24-channels-fixes-design.md).

void main() {
  group('buildDiscussionInitialState', () {
    Map<String, dynamic>? contentOf(List<StateEvent> events, String type) {
      for (final e in events) {
        if (e.type == type) return e.content;
      }
      return null;
    }

    test('обратная ссылка на канал проставляется всегда', () {
      final state = buildDiscussionInitialState(
        channelId: '!chan:h',
        channelJoinRule: 'public',
      );
      expect(contentOf(state, channelParentState), {'room_id': '!chan:h'});
    });

    test('чат канала всегда скрыт из списка чатов', () {
      final state = buildDiscussionInitialState(
        channelId: '!chan:h',
        channelJoinRule: 'invite',
      );
      expect(contentOf(state, 'com.liza.chat.topology'), {'hidden': true});
    });

    test('открытый канал: чат public + world_readable', () {
      final state = buildDiscussionInitialState(
        channelId: '!chan:h',
        channelJoinRule: 'public',
      );
      expect(contentOf(state, 'm.room.join_rules'), {'join_rule': 'public'});
      expect(contentOf(state, 'm.room.history_visibility'), {
        'history_visibility': 'world_readable',
      });
    });

    // AC:RL-channel-discussion-restricted-join/6
    test('закрытый канал: чат restricted по членству в канале + shared', () {
      final state = buildDiscussionInitialState(
        channelId: '!chan:h',
        channelJoinRule: 'invite',
      );
      expect(contentOf(state, 'm.room.join_rules'), {
        'join_rule': 'restricted',
        'allow': [
          {'type': 'm.room_membership', 'room_id': '!chan:h'},
        ],
      });
      expect(contentOf(state, 'm.room.history_visibility'), {
        'history_visibility': 'shared',
      });
    });
  });

  // JoinRules — enhanced enum: wire-значение лежит в .text, а .name отдаёт имя
  // Dart-идентификатора (knockRestricted вместо knock_restricted). Тест пинит
  // выбор .text в enableChannelComments.
  group('JoinRules.text — источник строки join_rule', () {
    test('wire-значения совпадают со спекой Matrix', () {
      expect(JoinRules.public.text, 'public');
      expect(JoinRules.invite.text, 'invite');
      expect(JoinRules.knockRestricted.text, 'knock_restricted');
    });

    test('.name расходится с wire-значением у составных правил', () {
      expect(JoinRules.knockRestricted.name, isNot('knock_restricted'));
    });
  });
}
