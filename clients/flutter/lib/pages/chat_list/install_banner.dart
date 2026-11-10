import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';

/// Состояние «пользователь закрыл плашку» — ТОЛЬКО в памяти вкладки.
///
/// Сознательно не persist: требование — показывать регулярно, поэтому при
/// открытии веб-клиента в новой вкладке плашка появляется снова.
class InstallBannerDismissal {
  static bool _dismissed = false;

  static bool get isDismissed => _dismissed;

  static void dismiss() => _dismissed = true;

  @visibleForTesting
  static void debugReset() => _dismissed = false;
}

/// Плашка «установить приложение» для веб-клиента.
///
/// Показывается ВНУТРИ приложения после авторизации (соседствует с
/// UpdateBanner в списке чатов), не на экране входа. С UpdateBanner не
/// конфликтует: та живёт только на нативных сборках, эта — только в вебе.
class InstallBanner extends StatefulWidget {
  const InstallBanner({
    super.key,
    required this.installUrl,
    this.isWeb = kIsWeb,
  });

  final String? installUrl;

  /// Вынесено параметром ради тестируемости: kIsWeb — константа компиляции.
  final bool isWeb;

  @override
  State<InstallBanner> createState() => _InstallBannerState();
}

class _InstallBannerState extends State<InstallBanner> {
  static const _allowedSchemes = {'https', 'http', 'itms-beta'};

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !_allowedSchemes.contains(uri.scheme)) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.installUrl;
    if (!widget.isWeb || url == null || url.isEmpty) {
      return const SizedBox.shrink();
    }
    if (InstallBannerDismissal.isDismissed) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Material(
      color: AppConfig.primaryColor,
      child: InkWell(
        onTap: () => _open(url),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.install_mobile, color: Colors.white, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    L10n.of(context).installAppBanner,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
                // InkResponse вместо IconButton: у IconButton минимальная
                // hit-area ~40×40 даже с VisualDensity.compact (density
                // срезает только визуальный padding, не constraints) — это
                // почти вдвое раздувало высоту плашки против UpdateBanner
                // (~40px). InkResponse без навязанных constraints даёт
                // компактную полосу, а radius держит палец-friendly область.
                InkResponse(
                  onTap: () => setState(InstallBannerDismissal.dismiss),
                  radius: 18,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
