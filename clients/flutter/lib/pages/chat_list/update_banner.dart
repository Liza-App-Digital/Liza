import 'package:flutter/material.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/utils/version_gate_service.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/update_gate.dart';

/// Плашка обновления в списке чатов.
///
/// Этапы анонс/мягкий/жёсткий (`GET /policy`) показывают плашку с датой
/// дедлайна; иначе — прежняя «Доступна новая версия» по `GET /version`
/// (висит, пока пользователь не обновится). Две плашки сразу не рисуем.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  @override
  Widget build(BuildContext context) {
    final matrix = Matrix.of(context);
    return ValueListenableBuilder<UpdatePolicy>(
      valueListenable: UpdatePolicyController.current,
      builder: (context, policy, _) {
        final important =
            policy.stage.index >= UpdateStage.announce.index &&
            policy.deadlineAt != null;
        if (important) {
          if (!matrix.updatePolicyController.bannerVisible) {
            return const SizedBox.shrink();
          }
          return _ImportantUpdateBanner(
            policy: policy,
            onDismiss: policy.stage == UpdateStage.announce
                ? () async {
                    await matrix.updatePolicyController.dismissBanner();
                    if (mounted) setState(() {});
                  }
                : null,
          );
        }
        return ValueListenableBuilder<VersionGateResult>(
          valueListenable: matrix.versionGateResult,
          builder: (context, result, _) {
            if (!result.needsUpdate) return const SizedBox.shrink();
            return _PlainUpdateBanner(url: result.updateUrl);
          },
        );
      },
    );
  }
}

class _PlainUpdateBanner extends StatelessWidget {
  const _PlainUpdateBanner({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppConfig.primaryColor,
      child: InkWell(
        onTap: () => openUpdateUrl(url),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.system_update, color: Colors.white, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    L10n.of(context).newVersionAvailable,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImportantUpdateBanner extends StatelessWidget {
  const _ImportantUpdateBanner({required this.policy, this.onDismiss});

  final UpdatePolicy policy;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    const onColor = Colors.white;
    return Material(
      key: const Key('update_banner_important'),
      color: AppConfig.primaryColor,
      child: InkWell(
        onTap: () => openUpdateUrl(policy.updateUrl),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
            child: Row(
              children: [
                const Icon(Icons.system_update, color: onColor, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.updateAnnounceTitle,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: onColor,
                        ),
                      ),
                      Text(
                        l10n.updateAnnounceBody(
                          formatUpdateDeadline(context, policy.deadlineAt!),
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onDismiss != null)
                  IconButton(
                    key: const Key('update_banner_dismiss'),
                    icon: const Icon(Icons.close, color: onColor, size: 20),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: onDismiss,
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: Icon(Icons.chevron_right, color: onColor, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
