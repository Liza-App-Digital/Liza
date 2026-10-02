import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';

/// Команда меню «/» бота (Liza Bot API `setMyCommands`).
class BotCommand {
  final String command;
  final String description;
  const BotCommand(this.command, this.description);
}

/// Меню «/» ботов: `GET {base}/liza/v1/bot-commands?mxid=<бот>`.
///
/// Команды бота — публичные метаданные (как `getMyCommands` у Telegram), токен
/// не нужен. Кэш в памяти на 5 минут по паре (homeserver, бот); загрузка ленивая
/// и дедуплицированная — безопасно звать из `initState`/`build`. Ошибка сети =
/// «команд нет» (подсказки просто не появятся), повтор — по TTL.
class BotCommandsRegistry {
  BotCommandsRegistry._();

  static final BotCommandsRegistry instance = BotCommandsRegistry._();

  /// Бампается, когда команды приехали — композер перестраивает подсказки.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  @visibleForTesting
  http.Client httpClient = http.Client();

  static const Duration _ttl = Duration(minutes: 5);

  final Map<String, List<BotCommand>> _commands = {};
  final Map<String, DateTime> _fetchedAt = {};
  final Set<String> _inFlight = {};

  String _key(Client client, String botMxid) =>
      '${client.homeserver?.host ?? ''}|$botMxid';

  /// Команды бота (пусто, если не загружены или их нет).
  List<BotCommand> commandsFor(Client client, String botMxid) =>
      _commands[_key(client, botMxid)] ?? const [];

  bool hasCommand(Client client, String botMxid, String name) =>
      commandsFor(client, botMxid).any((c) => c.command == name.toLowerCase());

  void ensureLoaded(Client client, String botMxid) {
    final key = _key(client, botMxid);
    if (_inFlight.contains(key)) return;
    final last = _fetchedAt[key];
    if (last != null && DateTime.now().difference(last) < _ttl) return;
    _inFlight.add(key);
    load(client, botMxid).whenComplete(() => _inFlight.remove(key));
  }

  @visibleForTesting
  Future<void> load(Client client, String botMxid) async {
    final key = _key(client, botMxid);
    final base = AppConfig.lizaBotApiBaseForHomeserver(client.homeserver?.host);
    final url = Uri.parse(
      '$base/liza/v1/bot-commands',
    ).replace(queryParameters: {'mxid': botMxid});
    try {
      final resp = await httpClient
          .get(url)
          .timeout(const Duration(seconds: 8));
      _fetchedAt[key] = DateTime.now();
      if (resp.statusCode != 200) {
        Logs().w('[BotCommands] $url → ${resp.statusCode}');
        return;
      }
      _commands[key] = parseBotCommands(
        jsonDecode(utf8.decode(resp.bodyBytes)),
      );
      revision.value++;
    } catch (e) {
      _fetchedAt[key] = DateTime.now();
      Logs().w('[BotCommands] load failed ($url): $e');
    }
  }

  @visibleForTesting
  void reset() {
    _commands.clear();
    _fetchedAt.clear();
    _inFlight.clear();
  }
}

/// Разбор ответа `/liza/v1/bot-commands`: `{"commands": [{command, description}]}`.
/// Мусорные записи пропускаем — меню не должно ронять композер.
List<BotCommand> parseBotCommands(Object? json) {
  final raw = json is Map ? json['commands'] : null;
  if (raw is! List) return const [];
  return [
    for (final c in raw)
      if (c is Map &&
          c['command'] is String &&
          (c['command'] as String).isNotEmpty)
        BotCommand(
          (c['command'] as String).toLowerCase(),
          c['description'] is String ? c['description'] as String : '',
        ),
  ];
}
