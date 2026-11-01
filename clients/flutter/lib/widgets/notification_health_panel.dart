import 'dart:async';

import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/notification_health.dart';
import 'package:liza/widgets/matrix.dart';

/// Один наблюдатель для панели настроек и предупреждения над чатами.
/// Чтение не зависит от build; несколько поверхностей разделяют single-flight.
class _HealthLifecycle extends WidgetsBindingObserver {
  static final instance = _HealthLifecycle();
  final _users = <NotificationHealth, int>{};

  void attach(NotificationHealth health) {
    if (_users.isEmpty) WidgetsBinding.instance.addObserver(this);
    _users[health] = (_users[health] ?? 0) + 1;
    unawaited(health.refresh());
  }

  void detach(NotificationHealth health) {
    final count = _users[health] ?? 0;
    if (count <= 1) {
      _users.remove(health);
    } else {
      _users[health] = count - 1;
    }
    if (_users.isEmpty) WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    for (final health in _users.keys.toList()) {
      unawaited(health.refresh());
    }
  }
}

/// Измеренные факты об уведомлениях. Доставка и показ здесь не проверяются.
class NotificationHealthPanel extends StatefulWidget {
  const NotificationHealthPanel({super.key, this.compact = false, this.health});

  final bool compact;
  final NotificationHealth? health;

  @override
  State<NotificationHealthPanel> createState() =>
      _NotificationHealthPanelState();
}

class _NotificationHealthPanelState extends State<NotificationHealthPanel> {
  late NotificationHealth _health;
  bool _busy = false;
  bool _actionFailed = false;

  @override
  void initState() {
    super.initState();
    _health = widget.health ?? NotificationHealth.instance;
    _HealthLifecycle.instance.attach(_health);
  }

  @override
  void didUpdateWidget(NotificationHealthPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.health ?? NotificationHealth.instance;
    if (identical(next, _health)) return;
    _HealthLifecycle.instance.detach(_health);
    _health = next;
    _HealthLifecycle.instance.attach(_health);
  }

  @override
  void dispose() {
    _HealthLifecycle.instance.detach(_health);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionFailed = false;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _actionFailed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSettings() async {
    final opened = await _health.openSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).notificationHealthSettingsFailed),
        ),
      );
    }
  }

  String _permissionText(L10n l10n, NotificationHealthSnapshot snapshot) {
    if (snapshot.isDenied) return l10n.notificationHealthDenied;
    final auth = snapshot.tags['liza.auth'];
    if (auth == 'not_determined') return l10n.notificationHealthNotDetermined;
    if (auth == 'provisional') return l10n.notificationHealthProvisional;
    if (snapshot.isAllowed) return l10n.notificationHealthAllowed;
    return l10n.notificationHealthUnknown;
  }

  String _reportText(L10n l10n, PushReportStatus status) => switch (status) {
    PushReportStatus.idle => l10n.notificationReportIdle,
    PushReportStatus.pending => l10n.notificationReportPending,
    PushReportStatus.httpAccepted => l10n.notificationReportAccepted,
    PushReportStatus.error => l10n.notificationReportError,
    PushReportStatus.disabled => l10n.notificationReportDisabled,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_health, Monitoring.pushReportStatus]),
    builder: (context, _) {
      final snapshot = _health.snapshot;
      if (widget.compact && !snapshot.isDenied) return const SizedBox.shrink();
      final l10n = L10n.of(context);
      final matrix = Matrix.of(context);
      final registered = matrix
          .backgroundPush
          ?.pusherRegisteredByClient[matrix.client.clientName];
      final observedAt = snapshot.observedAt?.toLocal();
      final materialL10n = MaterialLocalizations.of(context);
      final observed = observedAt == null
          ? l10n.notificationHealthNeverObserved
          : l10n.notificationHealthObservedAt(
              '${materialL10n.formatShortDate(observedAt)} '
              '${materialL10n.formatTimeOfDay(TimeOfDay.fromDateTime(observedAt))}',
            );
      final panel = Semantics(
        container: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16 + (widget.compact ? MediaQuery.paddingOf(context).top : 0),
            16,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _permissionText(l10n, snapshot),
                key: const ValueKey('notification-health-permission'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(observed),
              if (!widget.compact) ...[
                const SizedBox(height: 8),
                Text(l10n.notificationHealthDeliveryUnknown),
                const SizedBox(height: 8),
                Text(switch (registered) {
                  true => l10n.notificationRegistrationObserved,
                  false => l10n.notificationRegistrationMissing,
                  null => l10n.notificationRegistrationUnknown,
                }),
              ],
              const SizedBox(height: 8),
              Text(
                _actionFailed
                    ? l10n.notificationHealthActionFailed
                    : _reportText(l10n, Monitoring.pushReportStatus.value),
                key: const ValueKey('notification-report-status'),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    key: const ValueKey('notification-health-settings'),
                    onPressed: _busy ? null : () => _run(_openSettings),
                    child: Text(l10n.notificationHealthOpenSettings),
                  ),
                  TextButton(
                    key: const ValueKey('notification-health-send'),
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await matrix.sendPushDiagnostics();
                          }),
                    child: Text(l10n.notificationHealthSend),
                  ),
                  if (!widget.compact)
                    TextButton(
                      key: const ValueKey('notification-health-refresh'),
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await _health.refresh();
                            }),
                      child: Text(l10n.notificationHealthRefresh),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
      if (!widget.compact) return panel;
      // Баннер оставляет место чатам при крупном шрифте и открытой клавиатуре.
      final media = MediaQuery.of(context);
      final available = (media.size.height - media.viewInsets.bottom).clamp(
        0.0,
        double.infinity,
      );
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: available * 0.45),
        child: SingleChildScrollView(child: panel),
      );
    },
  );
}
