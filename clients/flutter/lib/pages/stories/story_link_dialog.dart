import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';

/// Ссылка на сторис для ручного копирования (LABA-2615): показывается, когда
/// браузер отверг запись в буфер. Нажатие «Копировать» — свежий жест при
/// фокусе на странице, запись в нём проходит. Возвращает `true`, если ссылка
/// скопирована.
class StoryLinkDialog extends StatelessWidget {
  final String url;

  const StoryLinkDialog({required this.url, super.key});

  static Future<bool> show(BuildContext context, String url) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => StoryLinkDialog(url: url),
      ) ??
      false;

  Future<void> _copy(BuildContext context) async {
    final navigator = Navigator.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: url));
    } catch (e, s) {
      // Ссылка остаётся выделяемой в диалоге — пользователь скопирует сам.
      Logs().w('Story link manual copy rejected', e, s);
      return;
    }
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return AlertDialog(
      title: Text(l10n.copyLink),
      content: SelectableText(url),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.close),
        ),
        TextButton(onPressed: () => _copy(context), child: Text(l10n.copy)),
      ],
    );
  }
}
