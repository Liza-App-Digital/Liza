import 'package:flutter/material.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/utils/support_chat.dart';
import 'package:liza/widgets/avatar.dart';

/// Плашка видна только на чипе «Компании» и не в поиске.
bool shouldShowCreateCompanyRow(
  ActiveFilter filter, {
  required bool isSearchMode,
}) => !isSearchMode && filter == ActiveFilter.spaces;

/// Плашка «Создать компанию» под списком компаний. Сам пользователь компанию
/// создать не может (1 инстанс = 1 компания, личную заводит админ — см.
/// howItWoks/lizaSpaces.md), поэтому тап → попап с описанием → чат поддержки.
/// Спека: docs/superpowers/specs/2026-09-15-create-company-support-entry-design.md.
class CreateCompanyListTile extends StatelessWidget {
  const CreateCompanyListTile({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final scheme = theme.colorScheme;
    final foreground = scheme.onPrimaryContainer;
    // Геометрия повторяет строку ChatListItem (поля 8 + contentPadding 8,
    // аватар 44, зазор 16): «+» стоит в слоте размера аватара на той же оси
    // (край 16, центр 38), заголовок — на 76 как у названий компаний.
    // Было 16+16 и «+» 32 → центр 48, «кривовато» (Надежда, 2026-10-21).
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppConfig.borderRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => confirmCreateCompanyRequest(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
            child: Row(
              children: [
                SizedBox.square(
                  key: const ValueKey('create_company_row_plus'),
                  dimension: Avatar.defaultSize,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(
                        AppConfig.borderRadius / 4,
                      ),
                    ),
                    child: Icon(Icons.add, color: foreground),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.createCompanyViaSupport,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.createCompanyListHint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.35,
                          color: foreground.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
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
