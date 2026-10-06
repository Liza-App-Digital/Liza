import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_commands_registry.dart';

/// Кнопка меню команд бота (Telegram «Menu») слева от поля ввода в DM с ботом,
/// задавшим `setMyCommands`. Слушает `BotCommandsRegistry.revision`: появляется,
/// как только команды приехали. Тап — список команд; выбор вставляет
/// `/<команда> ` в поле ввода (отправляет пользователь сам, можно дописать
/// аргументы).
class BotCommandsMenuButton extends StatelessWidget {
  final Room room;
  final TextEditingController controller;
  final FocusNode? focusNode;

  /// Программная правка поля не вызывает `TextField.onChanged` — сообщаем сами,
  /// чтобы композер переключился в режим «есть текст».
  final ValueChanged<String>? onChanged;
  final double height;

  const BotCommandsMenuButton({
    required this.room,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.height = 48,
    super.key,
  });

  void _insert(String command) {
    final text = '/$command ';
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onChanged?.call(text);
    focusNode?.requestFocus();
  }

  Future<void> _openMenu(
    BuildContext context,
    List<BotCommand> commands,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in commands)
              ListTile(
                title: Text(
                  '/${c.command}',
                  style: const TextStyle(fontFamily: 'RobotoMono'),
                ),
                subtitle: c.description.isEmpty ? null : Text(c.description),
                onTap: () => Navigator.of(context).pop(c.command),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _insert(picked);
  }

  @override
  Widget build(BuildContext context) {
    final botMxid = room.directChatMatrixID;
    if (botMxid == null) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: BotCommandsRegistry.instance.revision,
      builder: (context, _, _) {
        final commands = BotCommandsRegistry.instance.commandsFor(
          room.client,
          botMxid,
        );
        if (commands.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: height,
          width: height,
          child: IconButton(
            tooltip: L10n.of(context).botCommandsMenu,
            color: Theme.of(context).colorScheme.primary,
            icon: const Icon(Icons.menu),
            onPressed: () => _openMenu(context, commands),
          ),
        );
      },
    );
  }
}
