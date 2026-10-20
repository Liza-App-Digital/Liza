import 'package:flutter/material.dart';

import 'package:collection/collection.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_notifications/push_rule_extensions.dart';
import 'package:liza/utils/push_rule_defaults.dart';
import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/layouts/max_width_body.dart';
import '../../widgets/matrix.dart';
import '../../widgets/if_developer.dart';
import 'settings_notifications.dart';

class SettingsNotificationsView extends StatelessWidget {
  final SettingsNotificationsController controller;

  const SettingsNotificationsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !LizaThemes.isColumnMode(context),
        centerTitle: LizaThemes.isColumnMode(context),
        title: Text(L10n.of(context).notifications),
      ),
      body: MaxWidthBody(
        child: StreamBuilder(
          stream: Matrix.of(context).client.onSync.stream.where(
            (syncUpdate) =>
                syncUpdate.accountData?.any(
                  (accountData) => accountData.type == 'm.push_rules',
                ) ??
                false,
          ),
          builder: (BuildContext context, _) => _buildRules(context),
        ),
      ),
    );
  }

  // Правила читаем ВНУТРИ builder'а: снаружи StreamBuilder пересборка по sync
  // рисовала бы снимок правил с момента последнего setState.
  Widget _buildRules(BuildContext context) {
    final l10n = L10n.of(context);
    final pushRules = Matrix.of(context).client.globalPushRules;
    final deviations = PushRuleDefaults.deviations(pushRules);
    final masterRule = pushRules?.override?.firstWhereOrNull(
      (rule) => rule.ruleId == '.m.rule.master',
    );
    final pushCategories = [
      if (pushRules?.override?.isNotEmpty ?? false)
        (rules: pushRules?.override ?? [], kind: PushRuleKind.override),
      if (pushRules?.content?.isNotEmpty ?? false)
        (rules: pushRules?.content ?? [], kind: PushRuleKind.content),
      if (pushRules?.sender?.isNotEmpty ?? false)
        (rules: pushRules?.sender ?? [], kind: PushRuleKind.sender),
      if (pushRules?.underride?.isNotEmpty ?? false)
        (rules: pushRules?.underride ?? [], kind: PushRuleKind.underride),
    ];
    final theme = Theme.of(context);
    return SelectionArea(
      child: Column(
        children: [
          if (deviations != null && deviations.isNotEmpty) ...[
            ListTile(
              leading: Icon(
                Icons.warning_amber_outlined,
                color: theme.colorScheme.error,
              ),
              title: Text(l10n.pushRulesNotDefaultTitle),
              subtitle: Text(l10n.pushRulesNotDefaultBody),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton(
                  key: const ValueKey('push-rules-reset-to-default'),
                  onPressed: controller.isLoading
                      ? null
                      : () => controller.resetPushRulesToDefault(deviations),
                  child: Text(l10n.pushRulesResetToDefault),
                ),
              ),
            ),
            const Divider(),
          ],
          if (masterRule != null)
            ListTile(
              title: Text(masterRule.getPushRuleName(l10n)),
              subtitle: Text(masterRule.getPushRuleDescription(l10n)),
              trailing: Switch.adaptive(
                value: masterRule.enabled,
                onChanged: controller.isLoading
                    ? null
                    : (_) => controller.togglePushRule(
                        PushRuleKind.override,
                        masterRule,
                      ),
              ),
            ),
          // Сырые правила Matrix — только разработчику: у `suppress_*`
          // смысл переключателя инвертирован, и обычный пользователь
          // выключал ими доставку, не понимая этого (инцидент 2026-09-14).
          if (pushRules != null)
            IfDeveloper(
              child: Column(
                children: [
                  for (final category in pushCategories)
                    if (category.rules.any(_isVisibleRule)) ...[
                      ListTile(
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                category.kind.localized(L10n.of(context)),
                                style: TextStyle(
                                  color: theme.colorScheme.secondary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const DeveloperMark(),
                          ],
                        ),
                      ),
                      for (final rule in category.rules.where(_isVisibleRule))
                        ListTile(
                          title: Text(rule.getPushRuleName(L10n.of(context))),
                          subtitle: ValueListenableBuilder<int>(
                            valueListenable: Matrix.of(
                              context,
                            ).userRoleService.rolesVersion,
                            builder: (context, _, _) {
                              final isDeveloper = Matrix.of(
                                context,
                              ).isCurrentUserDeveloper;
                              return Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: rule.getPushRuleDescription(
                                        L10n.of(context),
                                      ),
                                    ),
                                    if (isDeveloper) ...[
                                      const TextSpan(text: ' '),
                                      WidgetSpan(
                                        child: InkWell(
                                          onTap: () => controller.editPushRule(
                                            rule,
                                            category.kind,
                                          ),
                                          child: Text(
                                            L10n.of(context).more,
                                            style: TextStyle(
                                              color: theme.colorScheme.primary,
                                              decoration:
                                                  TextDecoration.underline,
                                              decorationColor:
                                                  theme.colorScheme.primary,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                          trailing: Switch.adaptive(
                            value: rule.enabled,
                            onChanged: controller.isLoading
                                ? null
                                : rule.ruleId != '.m.rule.master' &&
                                      Matrix.of(
                                        context,
                                      ).client.allPushNotificationsMuted
                                ? null
                                : (_) => controller.togglePushRule(
                                    category.kind,
                                    rule,
                                  ),
                          ),
                        ),
                    ],
                ],
              ),
            ),
          const Divider(),
          IfDeveloper(
            child: ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: Row(
                children: [
                  Flexible(child: Text(L10n.of(context).testPushNotification)),
                  const SizedBox(width: 6),
                  const DeveloperMark(),
                ],
              ),
              trailing: controller.isSendingTestPush
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              onTap: controller.isSendingTestPush
                  ? null
                  : controller.sendTestPush,
            ),
          ),
        ],
      ),
    );
  }
}

const _hiddenRuleIds = {
  '.m.rule.contains_user_name',
  '.m.rule.suppress_notices',
  '.m.rule.call',
  '.m.rule.room_server_acl',
  '.m.rule.encrypted_room_one_to_one',
  '.m.rule.encrypted',
  '.m.rule.room.server_acl',
  '.im.vector.jitsi',
  '.m.rule.is_room_mention',
  '.m.rule.roomnotif',
  '.m.rule.tombstone',
};

bool _isVisibleRule(PushRule rule) =>
    rule.ruleId.startsWith('.m.') &&
    rule.ruleId != '.m.rule.master' &&
    !_hiddenRuleIds.contains(rule.ruleId);
