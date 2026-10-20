// ledger:RL-mcp-showcase-entry-points
// AC:RL-mcp-showcase-entry-points/1 AC:RL-mcp-showcase-entry-points/13
//
// Пункт «MCP-подключения» в настройках — только developer, с меткой «Р»;
// экран витрины в колоночном режиме без кнопки «назад» (Надежда, В5 18.10:
// «МСП подключения лучше отсюда убрать … для обычных пользователей нет …
// оставить только вот это одно окно»).
// guard.render: source-ассерт — полный рендер SettingsView требует
// SettingsController + Matrix + GoRouter (тот же компромисс, что в
// settings_invite_friends_test.dart); видимость на устройстве — manual в RL.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String settingsSrc;
  late String showcaseSrc;

  setUpAll(() {
    settingsSrc = File(
      'lib/pages/settings/settings_view.dart',
    ).readAsStringSync();
    showcaseSrc = File(
      'lib/pages/settings_integrations/settings_integrations_view.dart',
    ).readAsStringSync();
  });

  // AC:RL-mcp-showcase-entry-points/1
  test('AC-1: тайл MCP в настройках — внутри IfDeveloper, с DeveloperMark', () {
    final titleIdx = settingsSrc.indexOf('L10n.of(context).settingsMcpTitle');
    expect(titleIdx, isNot(-1), reason: 'пункта MCP в настройках нет');
    expect(
      'L10n.of(context).settingsMcpTitle'.allMatches(settingsSrc).length,
      1,
      reason: 'второй, ничем не загейченный тайл MCP',
    );
    final gateIdx = settingsSrc.lastIndexOf('IfDeveloper(', titleIdx);
    expect(gateIdx, isNot(-1));
    final gated = settingsSrc
        .substring(gateIdx, titleIdx)
        .replaceAll(RegExp(r'\s'), '');
    // Между гейтом и подписью — только открытие ListTile и его leading: тайл —
    // прямой ребёнок IfDeveloper, а не сосед после закрытого гейта.
    expect(
      RegExp(r'^IfDeveloper\(child:ListTile\(leading:constIcon\(Icons\.\w+\),title:Text\($')
          .hasMatch(gated),
      isTrue,
      reason: 'тайл MCP не внутри IfDeveloper:\n$gated',
    );
    final tileEnd = settingsSrc.indexOf('),\n                  ),', titleIdx);
    final tile = settingsSrc.substring(titleIdx, tileEnd);
    expect(tile, contains('trailing: const DeveloperMark()'));
    expect(tile, contains('context.go(AppRoutes.mcp)'));
  });

  // AC:RL-mcp-showcase-entry-points/13
  test('AC-13: витрина в колоночном режиме без кнопки «назад»', () {
    expect(
      showcaseSrc.contains('leading: isColumnMode ? null : const BackButton()'),
      isTrue,
    );
    expect(showcaseSrc.contains('automaticallyImplyLeading: !isColumnMode'),
        isTrue);
  });
}
