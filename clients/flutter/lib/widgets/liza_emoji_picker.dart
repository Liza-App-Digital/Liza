import 'package:flutter/material.dart';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/emoji_history_store.dart';
import 'package:liza/utils/emoji_search_index.dart';
import 'package:liza/widgets/liza_emoji_picker_view.dart';

/// Общий выбор для текста и реакций. Успешное использование учитывает caller.
class LizaEmojiPicker extends StatelessWidget {
  const LizaEmojiPicker({
    required this.history,
    required this.onEmojiSelected,
    this.onBackspacePressed,
    super.key,
  });

  final EmojiHistoryStore history;
  final OnEmojiSelected onEmojiSelected;
  final VoidCallback? onBackspacePressed;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return _PickerSession(
      key: ValueKey((history.prefs, history.userId, history.usage, locale)),
      history: history,
      locale: locale,
      onEmojiSelected: onEmojiSelected,
      onBackspacePressed: onBackspacePressed,
    );
  }
}

class _PickerSession extends StatefulWidget {
  const _PickerSession({
    required this.history,
    required this.locale,
    required this.onEmojiSelected,
    required this.onBackspacePressed,
    super.key,
  });

  final EmojiHistoryStore history;
  final Locale locale;
  final OnEmojiSelected onEmojiSelected;
  final VoidCallback? onBackspacePressed;

  @override
  State<_PickerSession> createState() => _PickerSessionState();
}

class _PickerSessionState extends State<_PickerSession> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _index = EmojiSearchIndex.instance;
  late final List<Emoji> _personal;
  late List<CategoryEmoji> Function(Locale) _emojiSet;
  var _query = '';
  late Category _category;

  @override
  void initState() {
    super.initState();
    _personal = widget.history.ranked().map(_index.resolve).toList();
    _category = _initialCategory;
    _updateCatalog();
  }

  Category get _initialCategory =>
      _personal.isEmpty ? Category.SMILEYS : Category.RECENT;

  void _updateCatalog() {
    final catalog = _query.trim().isEmpty
        ? [
            CategoryEmoji(Category.RECENT, _personal),
            ..._index.categories(widget.locale),
          ]
        : [CategoryEmoji(Category.RECENT, _index.search(_query))];
    // Identity callback стабильна при перестроении родителя/смене категории.
    _emojiSet = (_) => catalog;
  }

  void _onSearch(String query) {
    setState(() {
      _query = query;
      _category = query.trim().isEmpty ? _initialCategory : Category.RECENT;
      _updateCatalog();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final searching = _query.trim().isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            key: const ValueKey('emoji-search'),
            controller: _search,
            focusNode: _searchFocus,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l10n.emojiSearchHint,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('emoji-search-clear'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).deleteButtonTooltip,
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _search.clear();
                        _onSearch('');
                        _searchFocus.requestFocus();
                      },
                    ),
            ),
          ),
        ),
        if (!searching && _category == Category.RECENT)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(l10n.emojiRecentAndFrequent),
          ),
        Expanded(
          child: EmojiPicker(
            key: ValueKey(_query),
            onEmojiSelected: widget.onEmojiSelected,
            onBackspacePressed: widget.onBackspacePressed,
            onCategoryChanged: (category) {
              if (mounted) setState(() => _category = category);
            },
            customWidget: (config, state, showSearch) => LizaEmojiPickerView(
              config,
              state,
              showSearch,
              showCategoryBar: !searching,
            ),
            config: Config(
              height: null,
              locale: widget.locale,
              emojiSet: _emojiSet,
              emojiViewConfig: EmojiViewConfig(
                noRecents: Text(
                  searching
                      ? l10n.emojiSearchNoResults
                      : l10n.emoteKeyboardNoRecents,
                  textAlign: TextAlign.center,
                ),
                backgroundColor: theme.colorScheme.onInverseSurface,
              ),
              bottomActionBarConfig: const BottomActionBarConfig(
                enabled: false,
              ),
              categoryViewConfig: CategoryViewConfig(
                recentTabBehavior: RecentTabBehavior.NONE,
                initCategory: searching ? Category.RECENT : _initialCategory,
                extraTab: widget.onBackspacePressed == null
                    ? CategoryExtraTab.NONE
                    : CategoryExtraTab.BACKSPACE,
                backspaceColor: theme.colorScheme.primary,
                iconColor: theme.colorScheme.primary.withAlpha(128),
                iconColorSelected: theme.colorScheme.primary,
                indicatorColor: theme.colorScheme.primary,
                backgroundColor: theme.colorScheme.surface,
              ),
              skinToneConfig: SkinToneConfig(
                dialogBackgroundColor: Color.lerp(
                  theme.colorScheme.surface,
                  theme.colorScheme.primaryContainer,
                  0.75,
                )!,
                indicatorColor: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
