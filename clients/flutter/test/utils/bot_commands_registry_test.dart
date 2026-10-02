// ledger:RL-bot-commands-composer-menu
//
// Меню «/» бота (Liza Bot API setMyCommands → GET /liza/v1/bot-commands): реестр
// команд и подсказки композера. Требование — Даниэль Фурман 23.09: «setMyCommands
// и меню /: с нормальной отрисовкой на клиенте». Сервер — test_bot_commands.py.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/input_bar.dart';
import 'package:liza/utils/bot_commands_registry.dart';
import '../utils/test_client.dart';

const _bot = '@menu:bots.liza.ru';
const _human = '@bob:example.invalid';

void main() {
  final requested = <Uri>[];

  setUp(() {
    requested.clear();
    BotCommandsRegistry.instance.reset();
    BotCommandsRegistry.instance.httpClient = MockClient((req) async {
      requested.add(req.url);
      final mxid = req.url.queryParameters['mxid'];
      if (mxid == _bot) {
        return http.Response(
          jsonEncode({
            'commands': [
              {'command': 'start', 'description': 'Начать'},
              {'command': 'help', 'description': 'Помощь'},
              {'command': 'shop', 'description': 'Магазин'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(jsonEncode({'commands': []}), 200);
    });
  });

  Future<(Client, Room, Room, Room)> rooms() async {
    final client = await prepareTestClient(loggedIn: true);
    client.rooms.clear();
    client.rooms.addAll([
      Room(id: '!botdm:x', client: client),
      Room(id: '!humandm:x', client: client),
      Room(id: '!group:x', client: client),
    ]);
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        _bot: ['!botdm:x'],
        _human: ['!humandm:x'],
      },
    );
    return (
      client,
      client.getRoomById('!botdm:x')!,
      client.getRoomById('!humandm:x')!,
      client.getRoomById('!group:x')!,
    );
  }

  test('parseBotCommands: нормализует и пропускает мусор', () {
    final parsed = parseBotCommands({
      'commands': [
        {'command': 'Start', 'description': 'Начать'},
        {'command': '', 'description': 'пусто'},
        {'description': 'без имени'},
        'мусор',
        {'command': 'help'},
      ],
    });
    expect(parsed.map((c) => '${c.command}:${c.description}').toList(), [
      'start:Начать',
      'help:',
    ]);
    expect(parseBotCommands({'error': 'x'}), isEmpty);
    expect(parseBotCommands(null), isEmpty);
  });

  test(
    // AC:RL-bot-commands-composer-menu/3
    '«/» в чатах ∀ {DM с ботом с командами → есть; DM с человеком, группа → нет}',
    () async {
      final (client, botRoom, humanRoom, group) = await rooms();
      await BotCommandsRegistry.instance.load(client, _bot);
      await BotCommandsRegistry.instance.load(client, _human);

      final all = botCommandSuggestions(botRoom, '');
      expect(all.map((s) => s['name']), ['start', 'help', 'shop']);
      expect(all.first['type'], 'botcommand');
      expect(all.first['description'], 'Начать');
      expect(botCommandSuggestions(botRoom, 'sh').map((s) => s['name']), [
        'shop',
      ]);

      expect(botCommandSuggestions(humanRoom, ''), isEmpty);
      expect(botCommandSuggestions(group, ''), isEmpty);
      // Запрос публичный: только mxid бота, без токена.
      expect(requested.first.path, '/liza/v1/bot-commands');
      await client.dispose(closeDatabase: true);
    },
  );

  test(
    // AC:RL-bot-commands-composer-menu/4
    'команда из меню бота — бот-команда; Matrix-команды SDK остаются за SDK',
    () async {
      final (client, _, _, _) = await rooms();
      await BotCommandsRegistry.instance.load(client, _bot);
      final reg = BotCommandsRegistry.instance;
      expect(reg.hasCommand(client, _bot, 'shop'), isTrue);
      expect(reg.hasCommand(client, _bot, 'SHOP'), isTrue);
      expect(reg.hasCommand(client, _bot, 'unknown'), isFalse);
      expect(reg.hasCommand(client, _human, 'shop'), isFalse);
      // Статический набор BotFather/Лизы не потерян.
      expect(ChatController.isBotComposerCommand('newbot'), isTrue);
      // `send()` сначала проверяет client.commands: /me у SDK, не у бота.
      expect(client.commands.containsKey('me'), isTrue);
      await client.dispose(closeDatabase: true);
    },
  );

  test('сбой сети → команд нет, композер не падает; повтор по TTL', () async {
    final (client, botRoom, _, _) = await rooms();
    BotCommandsRegistry.instance.httpClient = MockClient(
      (_) async => throw Exception('offline'),
    );
    await BotCommandsRegistry.instance.load(client, _bot);
    expect(botCommandSuggestions(botRoom, ''), isEmpty);
    // ensureLoaded в пределах TTL после попытки не долбит сеть.
    var calls = 0;
    BotCommandsRegistry.instance.httpClient = MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    BotCommandsRegistry.instance.ensureLoaded(client, _bot);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    await client.dispose(closeDatabase: true);
  });
}
