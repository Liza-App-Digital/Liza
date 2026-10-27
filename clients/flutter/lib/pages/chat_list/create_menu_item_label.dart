import 'package:flutter/material.dart';

import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/hexagon_clipper.dart';

/// Подпись пункта меню «+» шапки списка чатов. Выделенный пункт получает
/// шестиугольник primary с «+» и жирный текст — тот же облик, что у строки
/// «+ Новый запрос» в списке (`NewLizaRequestListTile`), только мельче.
/// Сдвиг подписи относительно соседей — сам акцент (спека
/// `2026-10-23-create-menu-new-request-highlight-design.md`). Зазор значок →
/// подпись = ширина пробела в стиле подписи (Надежда 26.10: «как между
/// словами Новый и Запрос»), поэтому меряется, а не задан константой.
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

  static const _highlightedStyle = TextStyle(fontWeight: FontWeight.bold);

  /// Ширина пробела в [style] с учётом масштаба текста — межсловный зазор.
  static double wordGap(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

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
          SizedBox(
            width: wordGap(
              context,
              DefaultTextStyle.of(context).style.merge(_highlightedStyle),
            ),
          ),
        ],
        Text(label, style: highlighted ? _highlightedStyle : null),
        if (developerMark) ...[const SizedBox(width: 8), const DeveloperMark()],
      ],
    );
  }
}
