// ledger:RL-bot-api-interactive-client
import 'package:flutter/material.dart';

import 'package:alchemist/alchemist.dart';

import 'package:liza/utils/bot_interactive_markup.dart';
import 'package:liza/widgets/interactive_reply_keyboard.dart';

void main() {
  // AC:RL-bot-api-interactive-client/5
  goldenTest(
    'reply keyboard: реальные кнопки, строки и busy state',
    fileName: 'interactive_reply_keyboard',
    builder: () => GoldenTestGroup(
      columns: 1,
      children: [
        for (final busy in [false, true])
          GoldenTestScenario(
            name: busy ? 'ожидание' : 'выбор',
            child: SizedBox(
              width: 360,
              child: InteractiveReplyKeyboard(
                busy: busy,
                semanticsLabel: 'Клавиатура бота',
                onTap: (_) {},
                rows: const [
                  [
                    BotKeyboardButton('Телефон', 'request_contact'),
                    BotKeyboardButton('Геопозиция', 'request_location'),
                  ],
                  [BotKeyboardButton('Открыть приложение', 'web_app')],
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
