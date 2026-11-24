import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';

/// Второй шаг удаления аккаунта: показать, КАКОЙ аккаунт удаляется, и что
/// именно произойдёт. Возвращает `true` только при явном подтверждении.
///
/// Здесь НЕТ поля ввода. Раньше требовалось напечатать Matrix ID дословно, но
/// сам идентификатор диалог не показывал (LABA-2550): он всплывал лишь в
/// `errorText` после ошибочной попытки и обрезался многоточием, а у людей с
/// заданным ником полный MXID не показывается в клиенте нигде. Введённая
/// строка при этом никуда не уходила — сверялась с `client.userID`, уже
/// лежащим в клиенте, то есть была ритуалом против промаха, а не проверкой.
///
/// Промах отсекается иначе: `autofocus` стоит на «Отмена», поэтому
/// деструктивная кнопка не срабатывает по Enter. Именно поэтому диалог не
/// переиспользует `showOkCancelAlertDialog` — там `autofocus` висит на OK.
///
/// [Matrix] намеренно не трогаем: данные приходят параметрами, чтобы диалог
/// можно было проверить виджет-тестом без живого клиента.
Future<bool> showDeleteAccountDialog(
  BuildContext context, {
  required String accountTitle,
  required String accountLogin,
}) async {
  final l10n = L10n.of(context);
  final confirmed = await showAdaptiveDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog.adaptive(
        title: Text(l10n.deleteAccountConfirmTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(accountTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              // SelectableText, а не errorText: длинный логин переносится
              // целиком и его можно скопировать.
              SelectableText(
                accountLogin,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Text(l10n.deleteAccountConsequences),
              const SizedBox(height: 12),
              Text(l10n.deleteAccountRetention),
            ],
          ),
        ),
        actions: [
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop<bool>(false),
            autofocus: true,
            child: Text(l10n.cancel),
          ),
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop<bool>(true),
            child: Text(
              l10n.deleteAccountConfirmAction,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
