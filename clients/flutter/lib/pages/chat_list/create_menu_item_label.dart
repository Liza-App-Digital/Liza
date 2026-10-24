import 'package:flutter/material.dart';

import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/hexagon_clipper.dart';

/// Подпись пункта меню «+» шапки списка чатов. Выделенный пункт получает
/// шестиугольник primary с «+» и жирный текст — тот же облик, что у строки
/// «+ Новый запрос» в списке (`NewLizaRequestListTile`), только мельче.
/// Сдвиг подписи относительно соседей — сам акцент (спека
/// `2026-10-23-create-menu-new-request-highlight-design.md`).
/// ledger:RL-create-menu-order-agent-entry
class CreateMenuItemLabel extends StatelessWidget {
  final String label;
  final bool highlighted;
  final bool developerMark;

  const CreateMenuItemLabel({
    super.key,
    required this.label,
    this.highlighted = false,
    this.developerMark = false,
  });

  static const iconSize = 24.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (highlighted) ...[
          // DecoratedBox, а не Material: у PopupMenuItem уже свой ink-слой.
          ExcludeSemantics(
            child: SizedBox.square(
              key: const ValueKey('create_menu_new_request_icon'),
              dimension: iconSize,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: colorScheme.primary,
                  shape: const HexagonBorder(),
                ),
                child: Center(
                  child: Icon(
                    Icons.add,
                    size: 16,
                    color: colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Text(
          label,
          style: highlighted
              ? const TextStyle(fontWeight: FontWeight.bold)
              : null,
        ),
        if (developerMark) ...[const SizedBox(width: 8), const DeveloperMark()],
      ],
    );
  }
}
