import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/avatar.dart';

/// Одна строка контакта из телефонной книги в экране «Контакты».
///
/// matched (есть [mxid]) → кнопка «Написать»; unmatched → «Пригласить».
/// Вынесен отдельным виджетом ради тестируемости (страж рендерит реальный
/// виджет, а не реплику) — RL-contacts-screen-match-invite.
class ContactListTile extends StatelessWidget {
  final String displayName;
  final String? subtitle;

  /// mxid из lookup, если контакт уже в Liza; иначе null.
  final String? mxid;
  final void Function(String mxid) onWrite;
  final VoidCallback onInvite;

  const ContactListTile({
    super.key,
    required this.displayName,
    this.subtitle,
    required this.mxid,
    required this.onWrite,
    required this.onInvite,
  });

  bool get isOnLiza => mxid != null;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return ListTile(
      leading: Avatar(name: displayName),
      title: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: isOnLiza
          ? FilledButton.tonal(
              onPressed: () => onWrite(mxid!),
              child: Text(l10n.writeMessage),
            )
          : OutlinedButton.icon(
              onPressed: onInvite,
              icon: const Icon(Icons.person_add_alt_1, size: 18),
              label: Text(l10n.invite),
            ),
    );
  }
}
