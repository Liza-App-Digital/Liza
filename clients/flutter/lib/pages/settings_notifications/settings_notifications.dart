import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_notifications/push_rule_extensions.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/utils/push_rule_defaults.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:liza/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import '../../widgets/matrix.dart';
import 'settings_notifications_view.dart';

class SettingsNotifications extends StatefulWidget {
  const SettingsNotifications({super.key});

  @override
  SettingsNotificationsController createState() =>
      SettingsNotificationsController();
}

class SettingsNotificationsController extends State<SettingsNotifications> {
  bool isLoading = false;

  void onPusherTap(Pusher pusher) async {
    final delete = await showModalActionPopup<bool>(
      context: context,
      title: pusher.deviceDisplayName,
      message: '${pusher.appDisplayName} (${pusher.appId})',
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          label: L10n.of(context).delete,
          isDestructive: true,
          value: true,
        ),
      ],
    );
    if (delete != true) return;

    final success = await showFutureLoadingDialog(
      context: context,
      future: () => Matrix.of(context).client.deletePusher(
        PusherId(appId: pusher.appId, pushkey: pusher.pushkey),
      ),
    );

    if (success.error != null) return;

    setState(() {
      pusherFuture = null;
    });
  }

  Future<List<Pusher>?>? pusherFuture;

  void togglePushRule(PushRuleKind kind, PushRule pushRule) async {
    setState(() {
      isLoading = true;
    });
    try {
      final updateFromSync = Matrix.of(context).client.onSync.stream
          .where(
            (syncUpdate) =>
                syncUpdate.accountData?.any(
                  (accountData) => accountData.type == 'm.push_rules',
                ) ??
                false,
          )
          .first;
      await Matrix.of(
        context,
      ).client.setPushRuleEnabled(kind, pushRule.ruleId, !pushRule.enabled);
      await updateFromSync;
    } catch (e, s) {
      Logs().w('Unable to toggle push rule', e, s);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  /// Вернуть дефолты отклонившимся правилам из whitelist
  /// ([PushRuleDefaults.rules]); мьюты отдельных чатов не трогаются.
  Future<void> resetPushRulesToDefault(List<DefaultPushRule> deviations) async {
    setState(() {
      isLoading = true;
    });
    final client = Matrix.of(context).client;
    try {
      final updateFromSync = client.onSync.stream
          .where(
            (syncUpdate) =>
                syncUpdate.accountData?.any(
                  (accountData) => accountData.type == 'm.push_rules',
                ) ??
                false,
          )
          .first;
      await PushRuleDefaults.resetToDefaults(
        deviations,
        client.setPushRuleEnabled,
      );
      await updateFromSync;
    } catch (e, s) {
      Logs().w('Unable to reset push rules', e, s);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void editPushRule(PushRule rule, PushRuleKind kind) async {
    final theme = Theme.of(context);
    final action = await showAdaptiveDialog<PushRuleDialogAction>(
      context: context,
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 256),
        child: AlertDialog.adaptive(
          title: Text(rule.getPushRuleName(L10n.of(context))),
          content: Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: Material(
              borderRadius: BorderRadius.circular(AppConfig.borderRadius),
              color: theme.colorScheme.surfaceContainer,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  prettyJson(rule.toJson()),
                  style: TextStyle(color: theme.colorScheme.onSurface),
                ),
              ),
            ),
          ),
          actions: [
            AdaptiveDialogAction(
              onPressed: Navigator.of(context).pop,
              child: Text(L10n.of(context).close),
            ),
            if (!rule.ruleId.startsWith('.m.'))
              AdaptiveDialogAction(
                onPressed: () =>
                    Navigator.of(context).pop(PushRuleDialogAction.delete),
                child: Text(
                  L10n.of(context).delete,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (!mounted) return;
    switch (action) {
      case PushRuleDialogAction.delete:
        final consent = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).areYouSure,
          message: L10n.of(context).deletePushRuleCanNotBeUndone,
          okLabel: L10n.of(context).delete,
          isDestructive: true,
        );
        if (consent != OkCancelResult.ok) return;
        if (!mounted) return;
        setState(() {
          isLoading = true;
        });
        try {
          final updateFromSync = Matrix.of(context).client.onSync.stream
              .where(
                (syncUpdate) =>
                    syncUpdate.accountData?.any(
                      (accountData) => accountData.type == 'm.push_rules',
                    ) ??
                    false,
              )
              .first;
          await Matrix.of(context).client.deletePushRule(kind, rule.ruleId);
          await updateFromSync;
        } catch (e, s) {
          Logs().w('Unable to delete push rule', e, s);
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
        } finally {
          if (mounted) {
            setState(() {
              isLoading = false;
            });
          }
        }
        return;
    }
  }

  bool isSendingTestPush = false;

  void sendTestPush() async {
    setState(() => isSendingTestPush = true);
    try {
      final matrixState = Matrix.of(context);
      final plugin = matrixState.backgroundPush?.localNotificationsPlugin;
      if (plugin == null) {
        throw Exception('Push plugin not initialized');
      }

      DarwinNotificationDetails? darwinDetails;
      if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
        darwinDetails = const DarwinNotificationDetails(
          sound: 'liza_ding.aiff',
          presentSound: true,
          presentAlert: true,
          presentBadge: false,
          presentBanner: true,
          presentList: true,
        );
      }

      await plugin.show(
        0,
        L10n.of(context).testPushNotification,
        L10n.of(context).notificationLocalTestExplanation,
        NotificationDetails(
          iOS: darwinDetails,
          macOS: darwinDetails,
          android: AndroidNotificationDetails(
            AppConfig.pushNotificationsChannelId,
            L10n.of(context).notifications,
            importance: Importance.high,
            priority: Priority.max,
          ),
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).testNotificationSent)),
      );
    } catch (e) {
      Logs().w('Test push failed', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).testNotificationError('$e'))),
      );
    } finally {
      if (mounted) setState(() => isSendingTestPush = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsNotificationsView(this);
}

enum PushRuleDialogAction { delete }

String prettyJson(Map<String, Object?> json) {
  const decoder = JsonDecoder();
  const encoder = JsonEncoder.withIndent('    ');
  final object = decoder.convert(jsonEncode(json));
  return encoder.convert(object);
}
