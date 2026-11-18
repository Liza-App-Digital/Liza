// ledger:RL-emoji-history-search
import 'package:flutter/widgets.dart';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/emoji_search_index.dart';

void main() {
  final index = EmojiSearchIndex.instance;

  test('категории сохраняют имеющиеся переводы других языков', () {
    expect(index.categories(const Locale('de')), same(emojiSetGerman));
    expect(index.categories(const Locale('fr')), same(emojiSetFrance));
    expect(index.categories(const Locale('ru')), same(emojiSetRussian));
    expect(index.categories(const Locale('en')), same(emojiSetEnglish));
  });

  test('AC:RL-emoji-history-search/4 ru/en слова независимо от языка UI', () {
    for (final locale in [const Locale('ru'), const Locale('en')]) {
      expect(index.categories(locale), isNotEmpty);
      for (final query in ['сердце', 'heart', '  HeArT  ', 'СЕРДЦЕ']) {
        expect(index.search(query).map((e) => e.emoji), contains('❤️'));
      }
      for (final query in ['кот', 'cat']) {
        expect(index.search(query).map((e) => e.emoji), contains('🐈'));
      }
    }
  });

  test(
    'AC:RL-emoji-history-search/4 ё/е, все слова, Unicode и пустой результат',
    () {
      expect(
        index.search('еж').map((e) => e.emoji),
        index.search('ёж').map((e) => e.emoji),
      );
      expect(index.search('red heart').map((e) => e.emoji), contains('❤️'));
      expect(index.search('red heart asdfghjkl'), isEmpty);
      expect(index.search('😺').map((e) => e.emoji), contains('😺'));
      expect(index.search('qwertyxyz'), isEmpty);
      expect(index.search('   '), isEmpty);
      final results = index.search('face').map((e) => e.emoji).toList();
      expect(results.toSet(), hasLength(results.length));
    },
  );

  test(
    'AC:RL-emoji-history-search/5 resolve сохраняет точный emoji и skin metadata',
    () {
      expect(index.resolve('👍').hasSkinTone, isTrue);
      for (final exact in ['👍🏽', '👨‍👩‍👧', '🇷🇺', '❤️']) {
        expect(index.resolve(exact).emoji, exact);
      }
    },
  );
}
