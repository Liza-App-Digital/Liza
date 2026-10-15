import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';

/// Строка чекбоксов «На сервере {server}» / «В компании» под табами ролей.
/// Рисует только полезные чекбоксы (см. memberFilterUsefulness); если не
/// полезен ни один — плашку «все пользователи с сервера … и из компании».
class MemberFilterCheckboxes extends StatelessWidget {
  final String serverLabel;
  final bool hasServerName;
  final bool isSpace;
  final bool showServer;
  final bool showCompany;
  final bool onServerOnly;
  final bool inCompanyOnly;
  final ValueChanged<bool> onServerChanged;
  final ValueChanged<bool> onCompanyChanged;

  const MemberFilterCheckboxes({
    required this.serverLabel,
    required this.hasServerName,
    required this.isSpace,
    required this.showServer,
    required this.showCompany,
    required this.onServerOnly,
    required this.inCompanyOnly,
    required this.onServerChanged,
    required this.onCompanyChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    if (!showServer && !showCompany) {
      final text = isSpace
          ? (hasServerName
                ? l10n.memberFiltersAllFromServerAndCompany(serverLabel)
                : l10n.memberFiltersAllFromCompany)
          : (hasServerName
                ? l10n.memberFiltersAllFromServer(serverLabel)
                : null);
      if (text == null) return const SizedBox.shrink();
      return _AllMembersNote(text);
    }

    final server = MembershipCheckbox(
      label: l10n.memberFilterOnServer(serverLabel),
      value: onServerOnly,
      onChanged: onServerChanged,
    );
    final company = MembershipCheckbox(
      label: l10n.memberFilterInCompany,
      value: inCompanyOnly,
      onChanged: onCompanyChanged,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        children: [
          // Один чекбокс — на всю строку: длинному имени сервера нужна ширина.
          if (showServer) Expanded(child: server),
          if (showCompany) Expanded(child: company),
        ],
      ),
    );
  }
}

class _AllMembersNote extends StatelessWidget {
  final String text;

  const _AllMembersNote(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 10.0),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MembershipCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const MembershipCheckbox({
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: value,
          onChanged: (checked) => onChanged(checked ?? false),
          visualDensity: VisualDensity.compact,
        ),
        Flexible(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}
