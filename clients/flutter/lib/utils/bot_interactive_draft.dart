import 'package:flutter/foundation.dart';

import 'package:matrix/matrix.dart';

/// Только активные композеры. Регистрация снимается вместе с их State;
/// другой аккаунт/комната не получает чужой inline query.
class BotInteractiveDraft {
  static final _commands = Expando<Map<String, (String?, String)>>();
  static void markCommand(Client client, String roomId, String prefix) =>
      (_commands[client] ??= {})[roomId] = (client.accessToken, prefix);
  static bool selectedCommand(Client client, String roomId, String text) {
    final selected = _commands[client]?[roomId];
    return selected != null &&
        selected.$1 == client.accessToken &&
        (text == selected.$2 || text.startsWith('${selected.$2} '));
  }

  static final _queries = Expando<Map<String, bool Function()>>();
  static final _targets = Expando<Map<String, ValueChanged<String>>>();

  static void register(
    Client client,
    String roomId,
    ValueChanged<String> apply,
  ) => (_targets[client] ??= {})[roomId] = apply;

  static void registerQuery(
    Client client,
    String roomId,
    bool Function() active,
  ) => (_queries[client] ??= {})[roomId] = active;

  static bool queryActive(Client client, String roomId) =>
      _queries[client]?[roomId]?.call() ?? false;

  static void unregister(
    Client client,
    String roomId,
    ValueChanged<String> apply,
  ) {
    final targets = _targets[client];
    if (targets?[roomId] == apply) {
      targets?.remove(roomId);
      _queries[client]?.remove(roomId);
    }
  }

  static bool apply(Client client, String roomId, String text) {
    final target = _targets[client]?[roomId];
    if (target == null) return false;
    target(text);
    return true;
  }
}
