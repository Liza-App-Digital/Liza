import 'package:matrix/matrix.dart';

import 'package:liza/utils/push_rule_defaults.dart';

/// Р8 (спека 2026-11-12-push-sync-industry-alignment): причины «пуши не
/// приходят», которые лежат на стороне пользователя. Каждая — одна строка
/// экрана «Проверка уведомлений» с одной кнопкой исправления.
enum CheckupIssue {
  permissionDenied,
  alertsHidden,
  pusherMissing,
  accountMuted,
  secondCopy,
  outdatedBuild,
  batteryOptimized,
  macSleep,
}

enum CheckupAction { openSettings, reconnect, enableRules, update, none }

class CheckupFinding {
  const CheckupFinding(this.issue, this.action);
  final CheckupIssue issue;
  final CheckupAction action;

  @override
  bool operator ==(Object other) =>
      other is CheckupFinding && other.issue == issue && other.action == action;

  @override
  int get hashCode => Object.hash(issue, action);

  @override
  String toString() => '${issue.name}/${action.name}';
}

/// Семейство бандла без суффиксов `.data_message` / `.<device_id>`: старый
/// аккаунт Apple — `com.prodamus.*`, новый — `ru.prodamus.*`.
String? _bundleFamily(String appId) {
  if (appId.startsWith('com.prodamus.')) return 'com.prodamus';
  if (appId.startsWith('ru.prodamus.')) return 'ru.prodamus';
  return null;
}

/// Чистая оценка снимка. Неизвестное (`null`) — не проблема: экран не
/// пугает человека тем, чего не измерил.
List<CheckupFinding> evaluateNotificationCheckup({
  required String platform,
  required Map<String, String> tags,
  required List<Pusher>? pushers,
  required String? pushkey,
  required PushRuleSet? pushRules,
  required bool needsUpdate,
}) {
  final out = <CheckupFinding>[];
  final auth = tags['liza.auth'];
  if (auth == 'denied') {
    out.add(
      const CheckupFinding(
        CheckupIssue.permissionDenied,
        CheckupAction.openSettings,
      ),
    );
  } else if (auth == 'authorized' || auth == 'provisional') {
    final hidden = switch (platform) {
      'ios' || 'macos' =>
        tags['liza.alert'] == 'disabled' || tags['liza.alert_style'] == 'none',
      'android' =>
        tags['liza.channel_importance'] == 'none' ||
            tags['liza.channel_importance'] == 'missing',
      _ => false,
    };
    if (hidden) {
      out.add(
        const CheckupFinding(
          CheckupIssue.alertsHidden,
          CheckupAction.openSettings,
        ),
      );
    }
  }

  if (pushers != null && pushkey != null && pushkey.isNotEmpty) {
    final own = pushers.where((p) => p.pushkey == pushkey).firstOrNull;
    if (own == null) {
      out.add(
        const CheckupFinding(
          CheckupIssue.pusherMissing,
          CheckupAction.reconnect,
        ),
      );
    } else {
      final family = _bundleFamily(own.appId);
      final twin = pushers.any(
        (p) =>
            p.pushkey != pushkey &&
            p.deviceDisplayName == own.deviceDisplayName &&
            family != null &&
            _bundleFamily(p.appId) != null &&
            _bundleFamily(p.appId) != family,
      );
      if (twin) {
        out.add(
          const CheckupFinding(CheckupIssue.secondCopy, CheckupAction.none),
        );
      }
    }
  }

  final master = pushRules?.override
      ?.where((r) => r.ruleId == '.m.rule.master')
      .firstOrNull;
  final deviations = PushRuleDefaults.deviations(pushRules);
  if (master?.enabled == true ||
      (deviations != null && PushRuleDefaults.anySilencing(deviations))) {
    out.add(
      const CheckupFinding(
        CheckupIssue.accountMuted,
        CheckupAction.enableRules,
      ),
    );
  }

  if (needsUpdate) {
    out.add(
      const CheckupFinding(CheckupIssue.outdatedBuild, CheckupAction.update),
    );
  }

  if (platform == 'android' &&
      tags['liza.battery_optimization'] == 'optimized') {
    out.add(
      const CheckupFinding(
        CheckupIssue.batteryOptimized,
        CheckupAction.openSettings,
      ),
    );
  }

  // Не проверка, а факт ОС: показываем всегда на macOS.
  if (platform == 'macos') {
    out.add(const CheckupFinding(CheckupIssue.macSleep, CheckupAction.none));
  }
  return out;
}

/// «Включить»: снять общий выключатель и вернуть дефолты заглушающим правилам.
Future<void> enableAccountNotifications(
  PushRuleSet? rules,
  Future<void> Function(PushRuleKind kind, String ruleId, bool enabled)
  setEnabled,
) async {
  final master = rules?.override
      ?.where((r) => r.ruleId == '.m.rule.master')
      .firstOrNull;
  if (master?.enabled == true) {
    await setEnabled(PushRuleKind.override, '.m.rule.master', false);
  }
  final deviations = PushRuleDefaults.deviations(rules);
  if (deviations != null) {
    await PushRuleDefaults.resetToDefaults(
      deviations.where((r) => r.silences).toList(),
      setEnabled,
    );
  }
}
