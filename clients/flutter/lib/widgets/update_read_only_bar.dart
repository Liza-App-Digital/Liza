import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/widgets/update_gate.dart';

/// Плашка вместо поля ввода в режиме чтения обязательного обновления.
/// Черновик комнаты не трогается — после обновления он на месте.
class UpdateReadOnlyBar extends StatelessWidget {
  const UpdateReadOnlyBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return Container(
      key: const Key('update_read_only_bar'),
      margin: const EdgeInsets.all(8),
      constraints: const BoxConstraints(maxWidth: LizaThemes.maxTimelineWidth),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(24)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.updateReadOnlyComposer,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: () =>
                openUpdateUrl(UpdatePolicyController.current.value.updateUrl),
            child: Text(l10n.updateNow),
          ),
        ],
      ),
    );
  }
}

/// Показывать ли плашку вместо поля ввода: режим чтения и человек в комнате.
bool showUpdateReadOnlyBar(Room room) =>
    UpdatePolicyController.readOnly && room.membership == Membership.join;

/// Единая проверка режима чтения для действий, которые пишут в комнату
/// (отправка, ответ, пересылка, реакция, звонок…). `true` — действие
/// отбито, пользователю показана подсказка с кнопкой «Обновить».
bool blockedByUpdateReadOnly(BuildContext context) {
  if (!UpdatePolicyController.readOnly) return false;
  final l10n = L10n.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      key: const Key('update_read_only_snackbar'),
      content: Text(l10n.updateReadOnlyAction),
      action: SnackBarAction(
        label: l10n.updateNow,
        onPressed: () =>
            openUpdateUrl(UpdatePolicyController.current.value.updateUrl),
      ),
    ),
  );
  return true;
}
