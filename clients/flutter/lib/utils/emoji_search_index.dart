import 'package:flutter/widgets.dart';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';

/// Индекс каталога ru/en, независимый от singleton поиска пакета и языка UI.
class EmojiSearchIndex {
  EmojiSearchIndex._() {
    for (final categories in [emojiSetEnglish, emojiSetRussian]) {
      for (final category in categories) {
        for (final emoji in category.emoji) {
          _emoji.putIfAbsent(emoji.emoji, () => emoji);
          _keywords.update(
            emoji.emoji,
            (value) => '$value ${_normalize(emoji.name)}',
            ifAbsent: () => _normalize(emoji.name),
          );
        }
      }
    }
  }

  static final instance = EmojiSearchIndex._();
  final _emoji = <String, Emoji>{};
  final _keywords = <String, String>{};

  static String _normalize(String text) =>
      text.trim().toLowerCase().replaceAll('ё', 'е');

  List<CategoryEmoji> categories(Locale locale) =>
      getDefaultEmojiLocale(locale);

  List<Emoji> search(String query) {
    final normalized = _normalize(query);
    if (normalized.isEmpty) return [];
    final words = normalized.split(RegExp(r'\s+'));
    return _emoji.values.where((emoji) {
      final keywords = '${emoji.emoji} ${_keywords[emoji.emoji]}';
      return words.every(keywords.contains);
    }).toList();
  }

  /// Для истории сохраняем исходные code points, включая тон и ZWJ.
  Emoji resolve(String value) {
    final known = _emoji[value];
    if (known != null) return known;
    return Emoji(value, value);
  }
}
