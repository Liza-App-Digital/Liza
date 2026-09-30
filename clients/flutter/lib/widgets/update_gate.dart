import 'dart:async';

import 'package:flutter/material.dart';

import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/utils/voice_recording_guard.dart';
import 'package:liza/widgets/matrix.dart';

const _allowedUpdateSchemes = {'https', 'http', 'itms-beta'};

/// Открыть ссылку обновления (TestFlight / APK / установщик). Схемы — те же,
/// что принимала плашка обновления.
Future<void> openUpdateUrl(String? url) async {
  if (url == null || url.isEmpty) return;
  final uri = Uri.tryParse(url);
  if (uri == null || !_allowedUpdateSchemes.contains(uri.scheme)) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// «15 октября» — без обратного отсчёта по часам (требование ТЗ).
String formatUpdateDeadline(BuildContext context, DateTime deadline) =>
    DateFormat(
      'd MMMM',
      L10n.of(context).localeName,
    ).format(deadline.toLocal());

/// Полноэкранный слой обязательного обновления поверх живого дерева
/// приложения.
///
/// Слой, а не маршрут go_router: redirect ломает deep-link из пуша и не
/// видит звонок, а подмена дерева уронила бы черновики, sync и загрузки.
/// Под слоем всё продолжает работать; «Посмотреть чаты» снимает жёсткий
/// экран до следующего запуска — дальше режим чтения.
class UpdateGate extends StatefulWidget {
  const UpdateGate({
    required this.child,
    @visibleForTesting this.controller,
    @visibleForTesting this.hasActiveCall,
    super.key,
  });

  final Widget child;

  /// Подмена для тестов; в приложении — контроллер из [Matrix].
  final UpdatePolicyController? controller;

  /// Подмена для тестов; в приложении — звонилка из [Matrix].
  final bool Function()? hasActiveCall;

  /// Во время набора, записи голосового и звонка экран не показываем —
  /// показ откладывается до их окончания (опрос раз в [_busyPoll]).
  static bool isBusy({required bool hasActiveCall}) {
    if (hasActiveCall) return true;
    if (VoiceRecordingGuard.notifier.value != null) return true;
    final focused = FocusManager.instance.primaryFocus?.context;
    final editable = focused?.findAncestorWidgetOfExactType<EditableText>();
    return editable != null && editable.controller.text.trim().isNotEmpty;
  }

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

enum _Screen { none, soft, hard }

class _UpdateGateState extends State<UpdateGate> {
  static const _busyPoll = Duration(seconds: 2);

  _Screen _wanted = _Screen.none;
  bool _visible = false;
  bool _hardDismissed = false;
  bool _softMarked = false;
  bool _showHelp = false;
  Timer? _busyTimer;

  UpdatePolicyController get _controller =>
      widget.controller ?? Matrix.of(context).updatePolicyController;

  @override
  void initState() {
    super.initState();
    UpdatePolicyController.current.addListener(_onPolicy);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPolicy());
  }

  @override
  void dispose() {
    UpdatePolicyController.current.removeListener(_onPolicy);
    _busyTimer?.cancel();
    super.dispose();
  }

  void _onPolicy() {
    if (!mounted) return;
    final stage = UpdatePolicyController.current.value.stage;
    var wanted = _Screen.none;
    if (stage == UpdateStage.hard && !_hardDismissed) {
      wanted = _Screen.hard;
    } else if (stage == UpdateStage.soft &&
        (_wanted == _Screen.soft || _controller.shouldShowSoft)) {
      wanted = _Screen.soft;
    }
    if (wanted != _Screen.soft) _softMarked = false;
    _wanted = wanted;
    _reevaluate();
  }

  bool get _busy => UpdateGate.isBusy(
    hasActiveCall:
        widget.hasActiveCall?.call() ??
        Matrix.of(context).voipPlugin?.hasActiveCall ??
        false,
  );

  void _reevaluate() {
    if (!mounted) return;
    final visible = _wanted != _Screen.none && !_busy;
    if (_wanted == _Screen.none) {
      _busyTimer?.cancel();
      _busyTimer = null;
    } else {
      _busyTimer ??= Timer.periodic(_busyPoll, (_) => _reevaluate());
    }
    if (visible && _wanted == _Screen.soft && !_softMarked) {
      _softMarked = true;
      unawaited(_controller.markSoftShown());
    }
    if (visible != _visible) setState(() => _visible = visible);
  }

  void _close() {
    setState(() {
      if (_wanted == _Screen.hard) _hardDismissed = true;
      _wanted = _Screen.none;
      _visible = false;
      _showHelp = false;
    });
    _busyTimer?.cancel();
    _busyTimer = null;
  }

  Future<void> _postpone() async {
    await _controller.postpone();
    if (!mounted) return;
    _close();
  }

  @override
  Widget build(BuildContext context) {
    // expand: слой не должен ослаблять ограничения дерева приложения.
    return Stack(
      fit: StackFit.expand,
      children: [
        // Под экраном — живое дерево, но без фокуса и озвучки: иначе Tab и
        // VoiceOver/TalkBack добирались бы до чата под экраном.
        ExcludeFocus(
          excluding: _visible,
          child: ExcludeSemantics(excluding: _visible, child: widget.child),
        ),
        if (_visible)
          Positioned.fill(
            child: _UpdateScreen(
              hard: _wanted == _Screen.hard,
              policy: UpdatePolicyController.current.value,
              postponesLeft: _controller.postponesLeft,
              showHelp: _showHelp,
              onUpdate: () =>
                  openUpdateUrl(UpdatePolicyController.current.value.updateUrl),
              onPostpone: _postpone,
              onViewChats: _close,
              onHelp: () => setState(() => _showHelp = !_showHelp),
            ),
          ),
      ],
    );
  }
}

class _UpdateScreen extends StatelessWidget {
  const _UpdateScreen({
    required this.hard,
    required this.policy,
    required this.postponesLeft,
    required this.showHelp,
    required this.onUpdate,
    required this.onPostpone,
    required this.onViewChats,
    required this.onHelp,
  });

  final bool hard;
  final UpdatePolicy policy;
  final int postponesLeft;
  final bool showHelp;
  final VoidCallback onUpdate;
  final VoidCallback onPostpone;
  final VoidCallback onViewChats;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final deadline = policy.deadlineAt;
    final title = hard || deadline == null
        ? l10n.updateHardTitle
        : l10n.updateSoftTitle(formatUpdateDeadline(context, deadline));
    return Material(
      key: Key(hard ? 'update_gate_hard' : 'update_gate_soft'),
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.system_update,
                    size: 64,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hard ? l10n.updateHardBody : l10n.updateSoftBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge,
                  ),
                  if (PlatformInfos.isIOS || PlatformInfos.isMacOS) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.updateTestFlightHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('update_gate_update'),
                    onPressed: onUpdate,
                    child: Text(l10n.updateNow),
                  ),
                  const SizedBox(height: 8),
                  if (hard)
                    OutlinedButton(
                      key: const Key('update_gate_view_chats'),
                      onPressed: onViewChats,
                      child: Text(l10n.updateViewChats),
                    )
                  else
                    OutlinedButton(
                      key: const Key('update_gate_later'),
                      onPressed: onPostpone,
                      child: Text(l10n.updateLaterLeft(postponesLeft)),
                    ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('update_gate_help'),
                    onPressed: onHelp,
                    child: Text(l10n.updateCantUpdate),
                  ),
                  if (showHelp) ...[
                    Text(
                      l10n.updateCantUpdateBody,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    TextButton(
                      onPressed: () => openUpdateUrl('https://web.liza.ru'),
                      child: Text(l10n.updateOpenWeb),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
