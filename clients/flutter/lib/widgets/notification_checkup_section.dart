import 'dart:async';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/notification_checkup.dart';
import 'package:liza/utils/notification_health.dart';
import 'package:liza/utils/push_probe_api.dart';
import 'package:liza/utils/test_push_probe.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/update_gate.dart';

/// Р8: строки «причина → одна кнопка» и тестовый пуш. Живёт в полной панели
/// здоровья уведомлений (экран настроек уведомлений).
class NotificationCheckupSection extends StatefulWidget {
  const NotificationCheckupSection({
    super.key,
    required this.health,
    this.platform,
    this.loadPushers,
    this.loadProbeStatus,
  });

  final NotificationHealth health;

  /// Для тестов; по умолчанию — платформа отчёта.
  final String? platform;
  final Future<List<Pusher>?> Function(Client client)? loadPushers;

  /// Для тестов; по умолчанию — `GET /liza/push/v1/status` liza-bot-api.
  final Future<PushProbeStatus> Function(Client client)? loadProbeStatus;

  @override
  State<NotificationCheckupSection> createState() =>
      _NotificationCheckupSectionState();
}

class _NotificationCheckupSectionState
    extends State<NotificationCheckupSection> {
  List<Pusher>? _pushers;
  PushProbeStatus _probe = PushProbeStatus.off;
  bool _busy = false;
  bool _testRunning = false;
  TestPushResult? _testResult;

  // Без своего таймаута: результата никто не ждёт (спиннера нет), а пока
  // список не пришёл, строки про pusher молчат — «неизвестно» не проблема.
  static Future<List<Pusher>?> _defaultLoad(Client client) async {
    try {
      return await client.getPushers();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.health.addListener(_reloadPushers);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reloadPushers());
  }

  @override
  void dispose() {
    widget.health.removeListener(_reloadPushers);
    super.dispose();
  }

  static Future<PushProbeStatus> _defaultProbe(Client client) =>
      fetchPushProbeStatus(pushProbeBase(client.homeserver?.host));

  Future<void> _reloadPushers() async {
    if (!mounted) return;
    final client = Matrix.of(context).client;
    final probe = (widget.loadProbeStatus ?? _defaultProbe)(client);
    final pushers = await (widget.loadPushers ?? _defaultLoad)(client);
    final status = await probe;
    if (mounted) {
      setState(() {
        _pushers = pushers;
        _probe = status;
      });
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e, s) {
      Logs().w('[Push] checkup action failed', e, s);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).notificationHealthActionFailed),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reloadPushers();
  }

  Future<void> _runTestPush(Pusher own) async {
    final client = Matrix.of(context).client;
    setState(() {
      _testRunning = true;
      _testResult = null;
    });
    TestPushResult result;
    try {
      final openId = await client.requestOpenIdToken(client.userID!, {});
      result = await TestPushProbe(
        endpoint: testPushUrlFor(client.homeserver?.host),
        pushkey: own.pushkey,
        appId: own.appId,
        openIdToken: openId.accessToken,
        matrixServerName: openId.matrixServerName,
      ).run();
    } catch (e, s) {
      Logs().w('[Push] test push failed', e, s);
      result = const TestPushResult(TestPushStatus.rejected);
    }
    if (!mounted) return;
    setState(() {
      _testRunning = false;
      _testResult = result;
    });
  }

  String _text(L10n l10n, CheckupIssue issue) => switch (issue) {
    CheckupIssue.permissionDenied => l10n.notificationCheckupPermissionDenied,
    CheckupIssue.alertsHidden => l10n.notificationCheckupAlertsHidden,
    CheckupIssue.pusherMissing => l10n.notificationCheckupPusherMissing,
    CheckupIssue.accountMuted => l10n.notificationCheckupAccountMuted,
    CheckupIssue.secondCopy => l10n.notificationCheckupSecondCopy,
    CheckupIssue.outdatedBuild => l10n.notificationCheckupOutdated,
    CheckupIssue.batteryOptimized => l10n.notificationCheckupBattery,
    CheckupIssue.macSleep => l10n.notificationCheckupMacSleep,
  };

  Widget? _button(L10n l10n, MatrixState matrix, CheckupFinding finding) {
    final (label, action) = switch (finding.action) {
      CheckupAction.openSettings => (
        l10n.notificationHealthOpenSettings,
        () => widget.health.openSettings(),
      ),
      CheckupAction.reconnect => (
        l10n.notificationCheckupReconnect,
        () async => matrix.backgroundPush?.setupPush(),
      ),
      CheckupAction.enableRules => (
        l10n.notificationCheckupEnable,
        () => enableAccountNotifications(
          matrix.client.globalPushRules,
          matrix.client.setPushRuleEnabled,
        ),
      ),
      CheckupAction.update => (
        l10n.notificationCheckupUpdate,
        () => openUpdateUrl(matrix.versionGateResult.value.updateUrl),
      ),
      CheckupAction.none => (null, null),
    };
    if (label == null || action == null) return null;
    return TextButton(
      key: ValueKey('notification-checkup-action-${finding.issue.name}'),
      onPressed: _busy ? null : () => _act(action),
      child: Text(label),
    );
  }

  String _testText(L10n l10n) {
    if (_testRunning) return l10n.notificationTestPushRunning;
    final result = _testResult;
    if (result == null) return '';
    return switch (result.status) {
      TestPushStatus.delivered => l10n.notificationTestPushDelivered(
        ((result.elapsed?.inMilliseconds ?? 0) / 1000).toStringAsFixed(1),
      ),
      TestPushStatus.timedOut => l10n.notificationTestPushTimedOut,
      TestPushStatus.rejected => l10n.notificationTestPushRejected,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final matrix = Matrix.of(context);
    final platform = widget.platform ?? pushReportPlatform();
    return ValueListenableBuilder(
      valueListenable: matrix.versionGateResult,
      builder: (context, gate, _) {
        final pushkey = matrix.backgroundPush?.lastPushkey;
        final findings = evaluateNotificationCheckup(
          platform: platform,
          tags: widget.health.snapshot.tags,
          pushers: _pushers,
          pushkey: pushkey,
          pushRules: matrix.client.globalPushRules,
          needsUpdate: gate.needsUpdate,
        );
        final own = _pushers?.where((p) => p.pushkey == pushkey).firstOrNull;
        final canTest =
            (testPushEndpoint.isNotEmpty || _probe.test) &&
            own != null &&
            (platform == 'ios' || platform == 'android');
        final testText = _testText(l10n);
        return Column(
          key: const ValueKey('notification-checkup'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.notificationCheckupTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            if (findings.isEmpty)
              Text(
                l10n.notificationCheckupAllClear,
                key: const ValueKey('notification-checkup-clear'),
              ),
            for (final finding in findings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                      _text(l10n, finding.issue),
                      key: ValueKey(
                        'notification-checkup-${finding.issue.name}',
                      ),
                    ),
                    ?_button(l10n, matrix, finding),
                  ],
                ),
              ),
            if (canTest) ...[
              const SizedBox(height: 8),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  TextButton(
                    key: const ValueKey('notification-test-push'),
                    onPressed: _testRunning ? null : () => _runTestPush(own),
                    child: Text(l10n.notificationTestPushSend),
                  ),
                  if (testText.isNotEmpty)
                    Text(
                      testText,
                      key: const ValueKey('notification-test-push-result'),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
