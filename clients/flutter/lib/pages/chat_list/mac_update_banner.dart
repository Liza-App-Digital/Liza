import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/web_update_banner.dart';
import 'package:liza/utils/mac_update_checker.dart';

/// Плашка «Liza обновилась — Выйти» для macOS-процесса, пережившего замену
/// `Liza.app` на диске (см. [MacUpdateChecker]). Только выход, без
/// автоперезапуска: перезапуск из песочницы не проверен, а два процесса на
/// одной БД недопустимы (спека `2026-11-24-macos-stale-process-testflight-design.md`).
class MacUpdateBanner extends StatefulWidget {
  const MacUpdateBanner({super.key, this.checker, this.quit});

  /// Для тестов; по умолчанию — общий на процесс [MacUpdateChecker.instance].
  final MacUpdateChecker? checker;
  final VoidCallback? quit;

  @override
  State<MacUpdateBanner> createState() => _MacUpdateBannerState();
}

class _MacUpdateBannerState extends State<MacUpdateBanner> {
  late final MacUpdateChecker _checker =
      widget.checker ?? MacUpdateChecker.instance;

  @override
  void initState() {
    super.initState();
    _checker.start();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return WebUpdateBanner(
      updateAvailable: _checker.updateAvailable,
      reload: widget.quit ?? MacUpdateChecker.quit,
      message: l10n.macUpdateRestartNeeded,
      actionLabel: l10n.macUpdateQuit,
    );
  }
}
