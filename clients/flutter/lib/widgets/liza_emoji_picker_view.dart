import 'package:flutter/material.dart';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

/// Каталог пакета с полным освобождением контроллеров при смене поиска.
/// DefaultEmojiPickerView 4.4.0 не освобождает TabController.
class LizaEmojiPickerView extends EmojiPickerView {
  const LizaEmojiPickerView(
    super.config,
    super.state,
    super.showSearchBar, {
    super.key,
    this.showCategoryBar = true,
  });

  final bool showCategoryBar;

  @override
  State<LizaEmojiPickerView> createState() => _LizaEmojiPickerViewState();
}

class _LizaEmojiPickerViewState extends State<LizaEmojiPickerView>
    with SingleTickerProviderStateMixin, SkinToneOverlayStateMixin {
  late final TabController _tabs;
  late final PageController _pages;

  @override
  void initState() {
    super.initState();
    final index = widget.state.categoryEmoji.indexWhere(
      (e) => e.category == widget.config.categoryViewConfig.initCategory,
    );
    final initialIndex = index < 0 ? 0 : index;
    _tabs = TabController(
      length: widget.state.categoryEmoji.length,
      initialIndex: initialIndex,
      vsync: this,
    );
    _pages = PageController(initialPage: initialIndex)
      ..addListener(closeSkinToneOverlay);
  }

  @override
  void dispose() {
    closeSkinToneOverlay();
    _tabs.dispose();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = config.emojiViewConfig.getEmojiSize(constraints.maxWidth);
        final box = config.emojiViewConfig.getEmojiBoxSize(
          constraints.maxWidth,
        );
        return EmojiContainer(
          color: config.emojiViewConfig.backgroundColor,
          buttonMode: config.emojiViewConfig.buttonMode,
          child: Column(
            children: [
              if (widget.showCategoryBar)
                DefaultCategoryView(config, widget.state, _tabs, _pages),
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: widget.state.categoryEmoji.length,
                  onPageChanged: (index) {
                    _tabs.animateTo(
                      index,
                      duration:
                          config.categoryViewConfig.tabIndicatorAnimDuration,
                    );
                    widget.state.onCategoryChanged?.call(
                      widget.state.categoryEmoji[index].category,
                    );
                  },
                  itemBuilder: (context, index) {
                    final category = widget.state.categoryEmoji[index];
                    if (category.emoji.isEmpty) {
                      return Center(child: config.emojiViewConfig.noRecents);
                    }
                    return NotificationListener<ScrollNotification>(
                      onNotification: (_) {
                        closeSkinToneOverlay();
                        return false;
                      },
                      child: GridView.builder(
                        key: ValueKey(category.category),
                        primary: false,
                        padding: config.emojiViewConfig.gridPadding,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: config.emojiViewConfig.columns,
                          mainAxisSpacing:
                              config.emojiViewConfig.verticalSpacing,
                          crossAxisSpacing:
                              config.emojiViewConfig.horizontalSpacing,
                        ),
                        itemCount: category.emoji.length,
                        itemBuilder: (context, index) {
                          final emoji = category.emoji[index];
                          final linkKey = category.category.name + emoji.emoji;
                          return addSkinToneTargetIfAvailable(
                            hasSkinTone: emoji.hasSkinTone,
                            linkKey: linkKey,
                            child: EmojiCell.fromConfig(
                              emoji: emoji,
                              emojiSize: size,
                              emojiBoxSize: box,
                              categoryEmoji: category,
                              config: config,
                              onEmojiSelected: _select,
                              onSkinToneDialogRequested:
                                  (position, emoji, size, category) {
                                    closeSkinToneOverlay();
                                    if (!emoji.hasSkinTone ||
                                        !config.skinToneConfig.enabled) {
                                      return;
                                    }
                                    showSkinToneOverlay(
                                      position,
                                      emoji,
                                      size,
                                      category,
                                      config,
                                      _select,
                                      links[linkKey]!,
                                    );
                                  },
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _select(Category? category, Emoji emoji) {
    widget.state.onEmojiSelected(category, emoji);
    closeSkinToneOverlay();
  }
}
