import 'package:flutter/material.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';

Future<int?> showPermissionChooser(
  BuildContext context, {
  int currentLevel = 0,
  int maxLevel = ownerPowerLevel,
  bool isChannel = false,
}) async {
  return await showAdaptiveDialog<int>(
    context: context,
    builder: (context) {
      // Список кнопок переменный (зависит от maxLevel/currentLevel), поэтому
      // скругление углов вычисляем по фактической позиции в списке, а не по
      // фиксированным ролям — иначе при отсутствии верхней/нижней кнопки
      // углы соседней кнопки остаются квадратными.
      final entries = [
        // «Администратор» = 99 (владелец — 100, назначается только передачей
        // владения). Для порогов действий 99 тоже значит «админы и владелец».
        if (maxLevel >= adminPowerLevel && currentLevel != adminPowerLevel)
          (level: adminPowerLevel, label: L10n.of(context).admin),
        if (maxLevel >= moderatorPowerLevel &&
            currentLevel != moderatorPowerLevel)
          (level: moderatorPowerLevel, label: L10n.of(context).moderator),
        if (currentLevel != 0) (level: 0, label: L10n.of(context).normalUser),
      ];

      BorderRadius radiusFor(int index) {
        if (entries.length == 1) {
          return BorderRadius.circular(AppConfig.borderRadius);
        }
        if (index == 0) return AdaptiveDialogAction.topRadius;
        if (index == entries.length - 1) {
          return AdaptiveDialogAction.bottomRadius;
        }
        return AdaptiveDialogAction.centerRadius;
      }

      return AlertDialog.adaptive(
        // Заголовок по левому краю: Center здесь ломал ритм остальных
        // диалогов приложения.
        title: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            isChannel
                ? L10n.of(context).channelPermissions
                : L10n.of(context).chatPermissions,
          ),
        ),
        actions: [
          for (final (index, entry) in entries.indexed)
            AdaptiveDialogAction(
              bigButtons: true,
              borderRadius: radiusFor(index),
              onPressed: () => Navigator.of(context).pop<int>(entry.level),
              child: Center(child: Text(entry.label)),
            ),
        ],
      );
    },
  );
}
