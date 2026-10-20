import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';

/// Чекбоксы «На сервере {домен}» / «В компании {имя}» под табами ролей.
/// Рисует только полезные чекбоксы (см. memberFilterUsefulness); если не
/// полезен ни один — плашку «все пользователи с сервера … и из компании …».
///
/// [serverName] — всегда домен: имя сервера и имя компании различаются
/// (Надежда, 18.10), а домен не бывает чужим. [spaceName] — имя открытого
/// пространства, членство в котором проверяет «В компании»; у
/// подпространства подпись «В пространстве {имя}».
class MemberFilterCheckboxes extends StatelessWidget {
  final String serverName;
  final String spaceName;
  final bool isSpace;
  final bool isCompanyRoot;
  final bool showServer;
  final bool showCompany;
  final bool onServerOnly;
  final bool inCompanyOnly;
  final ValueChanged<bool> onServerChanged;
  final ValueChanged<bool> onCompanyChanged;

  const MemberFilterCheckboxes({
    required this.serverName,
    required this.spaceName,
    required this.isSpace,
    required this.isCompanyRoot,
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
    final hasServerName = serverName.isNotEmpty;
    if (!showServer && !showCompany) {
      final String? text;
      if (!isSpace) {
        text = hasServerName
            ? l10n.memberFiltersAllFromServer(serverName)
            : null;
      } else if (isCompanyRoot) {
        text = hasServerName
            ? l10n.memberFiltersAllFromServerAndCompany(serverName, spaceName)
            : l10n.memberFiltersAllFromCompany(spaceName);
      } else {
        text = hasServerName
            ? l10n.memberFiltersAllFromServerAndSpace(serverName, spaceName)
            : l10n.memberFiltersAllFromSpace(spaceName);
      }
      if (text == null) return const SizedBox.shrink();
      return _AllMembersNote(text);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      // Столбиком: домен и имя компании длинные, в одну строку на телефоне
      // обе подписи обрезались бы.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showServer)
            MembershipCheckbox(
              label: l10n.memberFilterOnServer(serverName),
              value: onServerOnly,
              onChanged: onServerChanged,
            ),
          if (showCompany)
            MembershipCheckbox(
              label: isCompanyRoot
                  ? l10n.memberFilterInCompany(spaceName)
                  : l10n.memberFilterInSpace(spaceName),
              value: inCompanyOnly,
              onChanged: onCompanyChanged,
            ),
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
        // Без «…»: домен и имя компании нужны целиком, длинное переносится.
        Flexible(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    ),
  );
}
