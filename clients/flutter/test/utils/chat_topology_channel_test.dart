// ledger:RL-channel-discussion-restricted-join
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/channel_discussion.dart';

void main() {
  test('channelChatType constant is "channel"', () {
    expect(channelChatType, 'channel');
  });

  test('константа типа обсуждения совпадает с серверной', () {
    expect(channelDiscussionChatType, 'channel_discussion');
  });

  group('discussionSettingsFor', () {
    test('открытый канал: чат public + world_readable', () {
      expect(discussionSettingsFor('public', '!chan:h'), {
        'join_rule': 'public',
        'history_visibility': 'world_readable',
      });
    });

    // AC:RL-channel-discussion-restricted-join/6 — та же таблица, что у
    // серверного discussion_settings_for (test_logic.py).
    test(
      'закрытый канал (любое не-public правило): restricted по членству в канале',
      () {
        for (final rule in [
          'invite',
          'knock',
          'restricted',
          'knock_restricted',
          null,
          'weird',
        ]) {
          expect(discussionSettingsFor(rule, '!chan:h'), {
            'join_rule': 'restricted',
            'allow': [
              {'type': 'm.room_membership', 'room_id': '!chan:h'},
            ],
            'history_visibility': 'shared',
          }, reason: '$rule');
        }
      },
    );

    test('content join_rules несёт allow только у restricted', () {
      expect(
        discussionJoinRulesContent(discussionSettingsFor('public', '!c:h')),
        {'join_rule': 'public'},
      );
      expect(
        discussionJoinRulesContent(discussionSettingsFor('invite', '!c:h')),
        {
          'join_rule': 'restricted',
          'allow': [
            {'type': 'm.room_membership', 'room_id': '!c:h'},
          ],
        },
      );
    });
  });

  group('isChannelPublic', () {
    test('только public считается открытым', () {
      expect(isChannelPublic('public'), isTrue);
      expect(isChannelPublic('invite'), isFalse);
      expect(isChannelPublic('knock'), isFalse);
      expect(isChannelPublic(null), isFalse);
    });
  });
}
