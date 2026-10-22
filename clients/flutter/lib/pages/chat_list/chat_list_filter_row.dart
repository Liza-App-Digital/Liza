import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/widgets/horizontal_mouse_wheel.dart';

/// Ряд чипов-вкладок списка чатов. Порядок меняется зажатием чипа и
/// перетаскиванием (замечание Надежды 20.10 «поменять порядок по зажатию»);
/// «Все» всегда первая и не перетаскивается, но прокручивается вместе с рядом
/// (замечание 21.10 «чтобы она не была зафиксирована»). Тап по чипу по-прежнему выбирает
/// вкладку: перетаскивание стартует только после задержки зажатия.
///
/// Виджет — единственный писатель сохранённого порядка
/// ([filterOrderPrefsKey] в [store]); при смене аккаунта перечитывает его.
/// ledger:RL-chat-list-filter-reorder
class ChatListFilterRow extends StatefulWidget {
  const ChatListFilterRow({
    super.key,
    required this.activeFilter,
    required this.onSelected,
    required this.store,
    required this.userId,
  });

  final ActiveFilter activeFilter;
  final ValueChanged<ActiveFilter> onSelected;
  final SharedPreferences store;
  final String? userId;

  @override
  State<ChatListFilterRow> createState() => _ChatListFilterRowState();
}

class _ChatListFilterRowState extends State<ChatListFilterRow> {
  final ScrollController _scrollController = ScrollController();
  late List<ActiveFilter> _order;

  @override
  void initState() {
    super.initState();
    _order = _readOrder();
  }

  @override
  void didUpdateWidget(ChatListFilterRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId || oldWidget.store != widget.store) {
      _order = _readOrder();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<ActiveFilter> _readOrder() {
    final userId = widget.userId;
    return resolveFilterOrder(
      userId == null
          ? null
          : widget.store.getStringList(filterOrderPrefsKey(userId)),
    );
  }

  void _onReorder(int oldIndex, int newIndex) {
    final movable = _order.skip(1).toList();
    if (newIndex > oldIndex) newIndex--;
    movable.insert(newIndex, movable.removeAt(oldIndex));
    setState(() => _order = [ActiveFilter.allChats, ...movable]);
    final userId = widget.userId;
    if (userId == null) return;
    widget.store.setStringList(
      filterOrderPrefsKey(userId),
      encodeFilterOrder(_order),
    );
  }

  Widget _chip(ActiveFilter filter) => FilterChip(
    selected: filter == widget.activeFilter,
    onSelected: (_) => widget.onSelected(filter),
    label: Text(filter.toLocalizedString(context)),
  );

  @override
  Widget build(BuildContext context) {
    final movable = _order.skip(1).toList();
    return SizedBox(
      height: 64,
      child: HorizontalMouseWheel(
        controller: _scrollController,
        child: ReorderableListView(
          scrollController: _scrollController,
          scrollDirection: Axis.horizontal,
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.only(right: 12),
          // «Все» — header: прокручивается вместе с рядом (как в Telegram),
          // но в индексы onReorder не входит, поэтому перед ней ничего не встанет.
          header: Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Center(child: _chip(ActiveFilter.allChats)),
          ),
          // Без Material перетаскиваемый чип теряет тему и тень.
          proxyDecorator: (child, _, _) =>
              Material(type: MaterialType.transparency, child: child),
          onReorder: _onReorder,
          children: [
            for (final (i, filter) in movable.indexed)
              ReorderableDelayedDragStartListener(
                key: ValueKey(filter),
                index: i,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Center(child: _chip(filter)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
