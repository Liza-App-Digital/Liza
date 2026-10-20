import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';

/// Микро-тег «Р» у функций, видимых только роли developer (задание Надежды
/// 18.10: «чёрная плашка с буквой Р»). Ставится рядом с подписью пункта, сам
/// гейт не делает — показ решают [IfDeveloper] / `isCurrentUserDeveloper`.
///
/// Цвета берутся из `onSurface`/`surface`, поэтому в тёмной теме плашка
/// инвертируется и остаётся контрастной.
class DeveloperMark extends StatelessWidget {
  const DeveloperMark({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: l10n.developerOnlyHint,
      excludeFromSemantics: true,
      child: Semantics(
        label: l10n.developerOnlyHint,
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.onSurface,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              l10n.developerMarkLetter,
              style: TextStyle(
                color: colorScheme.surface,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
