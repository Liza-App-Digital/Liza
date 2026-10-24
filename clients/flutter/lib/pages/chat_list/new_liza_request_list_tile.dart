import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/utils/liza_new_request.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/hexagon_clipper.dart';

/// Строка «+ Новый запрос» — последней под переписками на чипах «Все» и
/// «Агенты и боты» (задание Надежды 18.10: «сейчас важнее мотивировать
/// создавать новый запрос»). Новичку без DM Лизы она нужнее всего, поэтому
/// закреплённая «Лиза ИИ» первой строкой не требуется; список должен быть
/// досинкан (`synced`), иначе строка мигнёт под скелетоном.
/// ledger:RL-chat-list-agents-people-tabs
bool shouldShowNewRequestRow(
  ActiveFilter filter, {
  required bool isSearchMode,
  required bool synced,
}) =>
    !isSearchMode &&
    synced &&
    (filter == ActiveFilter.allChats || filter == ActiveFilter.agents);

class NewLizaRequestListTile extends StatefulWidget {
  const NewLizaRequestListTile({super.key});

  @override
  State<NewLizaRequestListTile> createState() => _NewLizaRequestListTileState();
}

class _NewLizaRequestListTileState extends State<NewLizaRequestListTile> {
  // Гейт от двойного тапа до появления барьера диалога загрузки: два тапа
  // подряд создали бы два чата-запроса.
  bool _opening = false;

  Future<void> _onTap() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await openNewLizaRequest(context);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Геометрия выровнена по ChatListItem: аватар 44 (Avatar.defaultSize) в
    // фиксированном SizedBox, visualDensity(-0.5), левый край leading 16px —
    // см. docs/superpowers/specs/2026-08-20-invite-people-row-alignment-design.md.
    // Шестиугольник — как у всех ИИ-аватаров (Надежда 23.10: «единообразие по
    // ИИ»); тап — у ListTile, своего InkWell у значка нет.
    return ListTile(
      visualDensity: const VisualDensity(vertical: -0.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: SizedBox(
        key: const ValueKey('new_liza_request_icon'),
        width: Avatar.defaultSize,
        height: Avatar.defaultSize,
        child: Material(
          color: theme.colorScheme.primary,
          shape: const HexagonBorder(),
          child: Icon(Icons.add, color: theme.colorScheme.onPrimary),
        ),
      ),
      title: Text(
        L10n.of(context).newLizaRequest,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      onTap: _onTap,
    );
  }
}
