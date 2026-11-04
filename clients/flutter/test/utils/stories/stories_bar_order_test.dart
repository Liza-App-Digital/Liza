import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/stories/frequent_contacts.dart';
import 'package:liza/utils/stories/stories_bar_order.dart';

DmActivity dm(String u, int ts) =>
    DmActivity(userId: u, roomId: '!$u', messageCount: 1, lastMessageTs: ts);

void main() {
  test('авторы сторис: свежая публикация левее', () {
    final r = sortByLatestStory<(String, int)>(
      [('a', 10), ('b', 30), ('c', 20)],
      latestTs: (x) => x.$2,
      tiebreak: (x) => x.$1,
    );
    expect(r.map((e) => e.$1), ['b', 'c', 'a']);
  });

  test('онлайн: вышедший позже левее, боты и исключённые не попадают', () {
    final r = rankOnlineContacts(
      [dm('@a:x', 1), dm('@b:x', 1), dm('@bot:x', 1), dm('@me:x', 1)],
      onlineSince: {
        '@a:x': DateTime(2026, 1, 1, 10),
        '@b:x': DateTime(2026, 1, 1, 12),
        '@bot:x': DateTime(2026, 1, 1, 13),
        '@me:x': DateTime(2026, 1, 1, 14),
      },
      excludedUserIds: {'@me:x'},
      isBot: (u) => u == '@bot:x',
    );
    expect(r.map((e) => e.userId), ['@b:x', '@a:x']);
  });

  test('недавние диалоги: по последнему сообщению, боты считаются', () {
    final r = rankRecentDialogs(
      [dm('@a:x', 10), dm('@bot:x', 30), dm('@c:x', 20), dm('@d:x', 40)],
      excludedUserIds: {'@d:x'},
    );
    expect(r.map((e) => e.userId), ['@bot:x', '@c:x', '@a:x']);
  });
}
