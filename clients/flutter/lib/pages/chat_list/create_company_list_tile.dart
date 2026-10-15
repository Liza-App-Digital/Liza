import 'package:flutter/material.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/utils/support_chat.dart';

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

  static const _plusSize = 32.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final scheme = theme.colorScheme;
    final foreground = scheme.onPrimaryContainer;
    // Карточка по макету: левый край на уровне аватаров списка (16), акцентная
    // подложка, «+» в светлом квадрате слева, заголовок и пояснение.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppConfig.borderRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => confirmCreateCompanyRequest(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                SizedBox.square(
                  key: const ValueKey('create_company_row_plus'),
                  dimension: _plusSize,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.add, size: 20, color: foreground),
                  ),
                ),
                const SizedBox(width: 12),
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
