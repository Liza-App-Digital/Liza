import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:universal_html/html.dart' as html;

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';

/// Плашка «Доступна новая версия — Обновить» для Web-вкладки, открытой до
/// последнего деплоя (см. `WebUpdateChecker`). Перезагрузка — только по тапу:
/// тихий reload унёс бы черновик и идущую отправку файла.
class WebUpdateBanner extends StatefulWidget {
  const WebUpdateBanner({
    super.key,
    required this.updateAvailable,
    this.reload = _reloadPage,
    this.message,
    this.actionLabel,
  });

  final ValueListenable<bool> updateAvailable;

  /// Текст и подпись действия; null — Web-вариант «Доступна новая версия —
  /// Обновить». macOS-плашка устаревшего процесса подставляет свои.
  final String? message;
  final String? actionLabel;

  /// Вынесено параметром ради тестируемости: в host-тестах окна браузера нет.
  final VoidCallback reload;

  static void _reloadPage() => html.window.location.reload();

  @override
  State<WebUpdateBanner> createState() => _WebUpdateBannerState();
}

class _WebUpdateBannerState extends State<WebUpdateBanner> {
  bool _reloading = false;

  void _onTap() {
    if (_reloading) return;
    setState(() => _reloading = true);
    widget.reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: widget.updateAvailable,
      builder: (context, available, _) {
        if (!available) return const SizedBox.shrink();
        final textStyle = theme.textTheme.bodyMedium?.copyWith(
          color: Colors.white,
        );
        return Material(
          color: AppConfig.primaryColor,
          child: InkWell(
            onTap: _reloading ? null : _onTap,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.system_update,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.message ?? L10n.of(context).newVersionAvailable,
                        style: textStyle,
                      ),
                    ),
                    Text(
                      widget.actionLabel ?? L10n.of(context).webUpdateReload,
                      style: textStyle?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
