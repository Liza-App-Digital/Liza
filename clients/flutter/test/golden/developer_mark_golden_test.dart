import 'package:flutter/material.dart';

import 'package:alchemist/alchemist.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/developer_mark.dart';

// Страж реестра регрессии: ledger:RL-developer-mark (см. tests/registry/).
// Golden Яруса 0 на РЕАЛЬНЫЙ DeveloperMark рядом с подписью пункта меню:
// светлая тема — тёмная плашка, тёмная — инвертированная светлая.

Widget _localized(Brightness brightness, Widget child) => Theme(
  data: ThemeData(brightness: brightness),
  child: Localizations(
    locale: const Locale('ru'),
    delegates: const [
      L10n.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    child: child,
  ),
);

void main() {
  // AC:RL-developer-mark/4 — golden светлой и тёмной темы.
  goldenTest(
    'метка разработчика «Р»: светлая / тёмная тема',
    fileName: 'developer_mark',
    pumpBeforeTest: (tester) async => tester.pumpAndSettle(),
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        for (final brightness in Brightness.values)
          GoldenTestScenario(
            name: brightness.name,
            child: _localized(
              brightness,
              Builder(
                builder: (context) => ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Добавить МСР'),
                        SizedBox(width: 6),
                        DeveloperMark(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
