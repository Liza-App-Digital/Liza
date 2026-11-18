// ledger:RL-emoji-history-search
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/emoji_history_store.dart';

void main() {
  late SharedPreferences prefs;
  late EmojiHistoryStore store;
  const alice = '@alice:example.invalid';
  const bob = '@alice:other.invalid';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = EmojiHistoryStore(prefs, alice, EmojiUsage.reaction);
  });

  test(
    'AC:RL-emoji-history-search/1 частота, затем последнее использование',
    () async {
      for (final emoji in ['😀', '🥰', '😀', '😺']) {
        await store.record(emoji);
      }
      expect(store.ranked(), ['😀', '😺', '🥰']);
      await store.record('🥰');
      expect(store.ranked(), ['🥰', '😀', '😺']);
      expect(store.ranked(limit: 2), ['🥰', '😀']);
    },
  );

  test(
    'AC:RL-emoji-history-search/2 persistence и отдельные аккаунты/назначения',
    () async {
      final other = EmojiHistoryStore(prefs, bob, EmojiUsage.reaction);
      final text = EmojiHistoryStore(prefs, alice, EmojiUsage.text);
      final pending = store.record('👍🏽');
      await other.record('😺');
      await text.record('🇷🇺');
      await pending;
      expect(store.ranked(), ['👍🏽']);
      expect(other.ranked(), ['😺']);
      expect(text.ranked(), ['🇷🇺']);
      final saved = {
        for (final key in prefs.getKeys()) key: prefs.getString(key)!,
      };
      SharedPreferences.setMockInitialValues(saved);
      final restarted = await SharedPreferences.getInstance();
      expect(identical(restarted, prefs), isFalse);
      expect(
        EmojiHistoryStore(restarted, alice, EmojiUsage.reaction).ranked(),
        ['👍🏽'],
      );
      expect(EmojiHistoryStore(restarted, bob, EmojiUsage.reaction).ranked(), [
        '😺',
      ]);
      expect(EmojiHistoryStore(restarted, alice, EmojiUsage.text).ranked(), [
        '🇷🇺',
      ]);
    },
  );

  test(
    'AC:RL-emoji-history-search/2 быстрые вызовы двух instances не теряют счётчик',
    () async {
      final reopened = EmojiHistoryStore(prefs, alice, EmojiUsage.reaction);
      final writes = <Future<void>>[];
      for (var i = 0; i < 30; i++) {
        writes.add((i.isEven ? store : reopened).record('👍'));
      }
      expect(reopened.ranked(), ['👍']);
      await Future.wait(writes);
      final saved = jsonDecode(prefs.getString(store.storageKey)!);
      expect(saved['entries'].single['count'], 30);
      expect(saved['entries'].single['last'], 30);
    },
  );

  test(
    'AC:RL-emoji-history-search/2 ошибка записи не ломает выбор и очередь',
    () async {
      final failing = _FailingPreferences(prefs);
      final resilient = EmojiHistoryStore(failing, alice, EmojiUsage.reaction);
      await resilient.record('👍');
      expect(resilient.ranked(), ['👍']);
      expect(prefs.getString(resilient.storageKey), isNull);
      await resilient.record('😺');
      expect(resilient.ranked(), ['😺', '👍']);
      expect(
        jsonDecode(prefs.getString(resilient.storageKey)!)['entries'],
        hasLength(2),
      );
    },
  );

  test(
    'AC:RL-emoji-history-search/2 повреждённые и неподходящие prefs безопасны',
    () async {
      for (final value in [
        'broken',
        '[]',
        '{"version":7,"entries":[]}',
        '{"version":1,"entries":[null,{"emoji":"x","count":-2,"last":1}]}',
      ]) {
        SharedPreferences.setMockInitialValues({store.storageKey: value});
        final newPrefs = await SharedPreferences.getInstance();
        final recovered = EmojiHistoryStore(
          newPrefs,
          alice,
          EmojiUsage.reaction,
        );
        expect(recovered.ranked(), isEmpty);
        await recovered.record('😺');
        expect(recovered.ranked(), ['😺']);
      }
      SharedPreferences.setMockInitialValues({store.storageKey: 42});
      final recovered = EmojiHistoryStore(
        await SharedPreferences.getInstance(),
        alice,
        EmojiUsage.reaction,
      );
      expect(recovered.ranked(), isEmpty);
      await recovered.record('😀');
      expect(recovered.ranked(), ['😀']);
    },
  );

  test(
    'AC:RL-emoji-history-search/2 хранит 100 последних, забывает старую частоту',
    () async {
      for (var i = 0; i < 3; i++) {
        await store.record('старый');
      }
      for (var i = 0; i < 100; i++) {
        await store.record('emoji-$i');
      }
      expect(store.ranked(limit: 200), hasLength(100));
      expect(store.ranked(limit: 200), isNot(contains('старый')));
      await store.record('старый');
      expect(store.ranked().first, 'старый');
      final saved = jsonDecode(prefs.getString(store.storageKey)!);
      expect(
        (saved['entries'] as List).firstWhere(
          (e) => e['emoji'] == 'старый',
        )['count'],
        1,
      );
    },
  );

  test(
    'AC:RL-emoji-history-search/3 пять уникальных quick слотов 0/1/5/8',
    () async {
      const defaults = ['👍', '👎', '❤️', '🔥', '🥰', '👍'];
      for (final count in [0, 1, 5, 8]) {
        final scoped = EmojiHistoryStore(
          prefs,
          '@$count:example.invalid',
          EmojiUsage.reaction,
        );
        for (var i = 0; i < count; i++) {
          await scoped.record('emoji-$i');
        }
        final quick = scoped.quickReactions(defaults);
        expect(quick, hasLength(5));
        expect(quick.toSet(), hasLength(5));
        if (count > 0) expect(quick.first, 'emoji-${count - 1}');
        if (count == 1) expect(quick.skip(1), defaults.take(4));
        if (count == 0) expect(quick, defaults.take(5));
      }
    },
  );

  test(
    'AC:RL-emoji-history-search/5 точный Unicode: skin tone, ZWJ, флаг',
    () async {
      const exact = ['👍🏽', '👨‍👩‍👧', '🇷🇺', '❤️', '❤'];
      for (final emoji in exact) {
        await store.record(emoji);
      }
      expect(store.ranked(), exact.reversed);
    },
  );
}

class _FailingPreferences extends Fake implements SharedPreferences {
  _FailingPreferences(this.delegate);
  final SharedPreferences delegate;
  var _fail = true;

  @override
  String? getString(String key) => delegate.getString(key);

  @override
  Future<bool> setString(String key, String value) {
    if (_fail) {
      _fail = false;
      throw StateError('недоступно хранилище');
    }
    return delegate.setString(key, value);
  }
}
