// ledger:RL-bot-commands-safety-menu
//
// Команда из меню бота (setMyCommands) НИКОГДА не исполняется как Matrix-команда
// клиента, даже при совпадении имени со встроенной (`leave`, `logout`, `ban`…):
// бот вправе так назвать команду, а пользователь, выбравший `/leave` из меню
// бота, не должен выйти из чата. Встроенные команды, которых у бота нет,
// работают как раньше (bot-api-compat-fixes, D11).
//
// Поднять полный ChatPage в тесте нельзя (см. update_read_only_guards_test.dart),
// поэтому: решение — РЕАЛЬНЫЙ `ChatController.routeComposerCommand` на реальном
// `client.commands` SDK; эффект — реальная `Room.sendTextEvent` с тем
// `parseCommands`, что выставляет `send()`; связка `send()` → маршрут — по
// исходнику.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/chat.dart';
import '../../utils/test_client.dart';

const _builtins = [
  'leave',
  'logout',
  'logoutall',
  'ban',
  'kick',
  'invite',
  'join',
  'me',
];

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
  });
  tearDown(() => client.dispose(closeDatabase: true));

  test(
    'встроенные команды действительно есть у SDK (иначе тест ниже пуст)',
    () {
      for (final name in _builtins) {
        expect(client.commands.containsKey(name), isTrue, reason: name);
      }
    },
  );

  test('∀ встроенная команда из меню бота → текстом боту', () {
    // AC:RL-bot-commands-safety-menu/1
    for (final name in [..._builtins, 'logoutAll', 'LEAVE']) {
      expect(
        ChatController.routeComposerCommand(
          name,
          matrixCommands: client.commands.keys,
          botHasCommand: true,
        ),
        ComposerCommandRoute.bot,
        reason: name,
      );
    }
  });

  test('встроенные команды, которых у бота нет, работают как раньше; '
      'статический набор BotFather/Лизы — боту; прочее — вопрос', () {
    // AC:RL-bot-commands-safety-menu/2
    for (final name in _builtins) {
      expect(
        ChatController.routeComposerCommand(
          name,
          matrixCommands: client.commands.keys,
          botHasCommand: false,
        ),
        ComposerCommandRoute.matrix,
        reason: name,
      );
    }
    expect(
      ChatController.routeComposerCommand(
        'newbot',
        matrixCommands: client.commands.keys,
        botHasCommand: false,
      ),
      ComposerCommandRoute.bot,
    );
    expect(
      ChatController.routeComposerCommand(
        'shop',
        matrixCommands: client.commands.keys,
        botHasCommand: false,
      ),
      ComposerCommandRoute.unknown,
    );
  });

  test('/leave и /logout из меню бота: уходят текстом, из чата не выходим, '
      'сессия жива', () async {
    // AC:RL-bot-commands-safety-menu/1
    final room = Room(id: '!1234:fakeServer.notExisting', client: client);
    client.rooms.add(room);
    FakeMatrixApi.calledEndpoints.clear();

    for (final text in ['/leave', '/logout', '/logoutAll']) {
      final route = ChatController.routeComposerCommand(
        ChatController.composerCommandPattern.firstMatch(text)![1]!,
        matrixCommands: client.commands.keys,
        botHasCommand: true,
      );
      // `send()`: маршрут «бот» → parseCommands:false.
      await room.sendTextEvent(
        text,
        parseCommands: route != ComposerCommandRoute.bot,
      );
    }

    final called = FakeMatrixApi.calledEndpoints.keys.toList();
    expect(called.where((k) => k.endsWith('/leave')), isEmpty);
    expect(called.where((k) => k.contains('/logout')), isEmpty);
    expect(client.isLogged(), isTrue);
    final bodies = FakeMatrixApi.calledEndpoints.entries
        .where((e) => e.key.contains('/send/m.room.message/'))
        .expand((e) => e.value)
        .map((b) => b.toString())
        .toList();
    for (final text in ['/leave', '/logout', '/logoutAll']) {
      expect(
        bodies.any((b) => b.contains('"body":"$text"')),
        isTrue,
        reason: text,
      );
    }
  });

  test(
    'send() решает маршрут через routeComposerCommand с меню бота-собеседника, '
    'а не проверкой client.commands впереди',
    () {
      // AC:RL-bot-commands-safety-menu/1
      final chat = File('lib/pages/chat/chat.dart').readAsStringSync();
      final body = chat.substring(
        chat.indexOf('  Future<void> send() async {'),
      );
      final sendBody = body.substring(0, body.indexOf('\n  }\n'));
      expect(sendBody, contains('routeComposerCommand('));
      expect(sendBody, contains('BotCommandsRegistry.instance.hasCommand('));
      expect(sendBody, isNot(contains('sendingClient.commands.keys.contains')));
      expect(
        RegExp(
          r'case ComposerCommandRoute\.bot:\s*parseCommands = false;',
        ).hasMatch(sendBody),
        isTrue,
      );
    },
  );
}
