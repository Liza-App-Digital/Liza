import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_consent.dart';
import 'package:liza/utils/bot_interactive_markup.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/widgets/interactive_query_result_dialog.dart';

/// Сервер повторно проверяет membership/ownership и фильтры при submit.
/// Диалог не отправляет список кандидатов: наружу выходит только явный выбор.
Future<bool> submitBotKeyboardSelection({
  required BuildContext context,
  required BotInteractiveApi api,
  required Room room,
  required String queryId,
  required String sessionId,
  required BotKeyboardButton button,
  required bool Function() isCurrent,
}) async {
  bool current() => context.mounted && api.isCurrent && isCurrent();
  if (!current()) return false;
  final choices = <String, String>{};
  String title;
  switch (button.action) {
    case 'request_users':
      title = L10n.of(context).botChooseUsers;
      final users = await room.requestParticipants([Membership.join]);
      if (!current()) return false;
      for (final user in users) {
        final wantsBot = button.parameters?['user_is_bot'];
        if (wantsBot is bool) {
          final bot = await api.resolve(mxid: user.id);
          if (!current()) return false;
          if ((bot != null) != wantsBot) continue;
        }
        choices[user.id] = user.calcDisplayname();
      }
    case 'request_chat':
      title = L10n.of(context).botChooseChat;
      for (final candidate in room.client.rooms) {
        if (candidate.membership == Membership.join &&
            !candidate.isSpace &&
            !candidate.isChannel &&
            candidate.directChatMatrixID == null) {
          choices[candidate.id] = candidate.getLocalizedDisplayname();
        }
      }
    default:
      return false;
  }
  if (!current()) return false;
  final selected = <String>{};
  final rawMax = button.parameters?['max_quantity'];
  final maximum = button.action == 'request_users' && rawMax is int
      ? rawMax.clamp(1, 10)
      : 1;
  final picked = await showInteractiveConsent<List<String>>(
    context: context,
    isCurrent: current,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in choices.entries)
                  CheckboxListTile(
                    title: Text(entry.value),
                    subtitle: Text(entry.key),
                    value: selected.contains(entry.key),
                    onChanged: (value) => setDialogState(() {
                      if (value == true && selected.length < maximum) {
                        selected.add(entry.key);
                      }
                      if (value != true) selected.remove(entry.key);
                    }),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L10n.of(context).cancel),
          ),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.of(context).pop(selected.toList()),
            child: Text(L10n.of(context).send),
          ),
        ],
      ),
    ),
  );
  if (!current() ||
      picked == null ||
      picked.isEmpty ||
      picked.any((id) => !choices.containsKey(id))) {
    return false;
  }
  final selection = button.action == 'request_users'
      ? <String, dynamic>{'user_ids': picked}
      : <String, dynamic>{'chat_id': picked.single};
  await api.request(
    'POST',
    '/liza/interactive/query/${Uri.encodeComponent(queryId)}/submit',
    body: {'session_id': sessionId, 'selection': selection},
  );
  return current();
}

/// Вызывается native Mini App bridge. ID связывает запрос с пользователем,
/// приложением и сеансом на сервере; сам ID не считается согласием на отправку.
Future<bool> handlePreparedBotRequest({
  required BuildContext context,
  required Client client,
  required Room room,
  required String preparedId,
  required String sessionId,
  required bool Function() isCurrent,
  String? expectedBotMxid,
  String? appId,
}) async {
  final api = BotInteractiveApi(client);
  String? queryId;
  var completed = false;
  DateTime? expiry;
  bool current() =>
      context.mounted &&
      api.isCurrent &&
      isCurrent() &&
      expiry != null &&
      DateTime.now().isBefore(expiry);
  try {
    final prepared = await api.request(
      'GET',
      '/liza/interactive/prepared/${Uri.encodeComponent(preparedId)}',
      query: {
        'session_id': sessionId,
        'room_id': room.id,
        if (expectedBotMxid != null) 'expected_bot_mxid': expectedBotMxid,
        if (appId != null) 'app_id': appId,
      },
    );
    expiry = interactiveExpiry(prepared['expires_at']);
    final id = prepared['query_id'];
    if (id is! String) return false;
    queryId = id;
    if (!current()) return false;
    if (prepared['kind'] == 'prepared_keyboard') {
      final button = BotKeyboardButton.parse(prepared['button']);
      if (button == null) return false;
      completed = await submitBotKeyboardSelection(
        context: context,
        api: api,
        room: room,
        queryId: id,
        sessionId: sessionId,
        button: button,
        isCurrent: current,
      );
      return completed;
    }
    final results = prepared['results'];
    if (prepared['kind'] != 'prepared_message' || results is! List) {
      return false;
    }
    completed = await _sendQueryResult(
      context: context,
      api: api,
      room: room,
      queryId: id,
      sessionId: sessionId,
      results: results,
      isCurrent: current,
    );
    return completed;
  } finally {
    if (queryId != null && !completed && api.isCurrent) {
      try {
        await api.request(
          'POST',
          '/liza/interactive/query/${Uri.encodeComponent(queryId)}/cancel',
          body: {'session_id': sessionId},
        );
      } catch (_) {
        /* TTL очистит остаток. */
      }
    }
    api.dispose();
  }
}

DateTime? interactiveExpiry(Object? value) => value is num
    ? DateTime.fromMillisecondsSinceEpoch(
        (value * (value < 100000000000 ? 1000 : 1)).toInt(),
      )
    : value is String
    ? DateTime.tryParse(value)
    : null;

Future<bool> _sendQueryResult({
  required BuildContext context,
  required BotInteractiveApi api,
  required Room room,
  required String queryId,
  required String sessionId,
  required List results,
  required bool Function() isCurrent,
}) async {
  bool current() => context.mounted && api.isCurrent && isCurrent();
  return await showInteractiveConsent<bool>(
        context: context,
        isCurrent: current,
        builder: (context) => InteractiveQueryResultDialog(
          api: api,
          queryId: queryId,
          sessionId: sessionId,
          results: results,
          isCurrent: current,
          send: (content, txid) => room.sendEvent(content, txid: txid),
        ),
      ) ==
      true;
}

/// Выбор результата уже существующего WebApp/inline query без подмены prepared ID.
/// Pending возвращает false: host может продолжить ограниченный TTL polling.
Future<bool> handleBotQueryResult({
  required BuildContext context,
  required Client client,
  required Room room,
  required String queryId,
  required String sessionId,
  required bool Function() isCurrent,
}) async {
  final api = BotInteractiveApi(client);
  try {
    final query = await api.request(
      'GET',
      '/liza/interactive/query/${Uri.encodeComponent(queryId)}',
      query: {'session_id': sessionId},
    );
    final expiry = interactiveExpiry(query['expires_at']);
    bool current() =>
        context.mounted &&
        api.isCurrent &&
        isCurrent() &&
        expiry != null &&
        DateTime.now().isBefore(expiry);
    final results = query['results'];
    if (!current() || query['status'] != 'answered' || results is! List) {
      return false;
    }
    return await _sendQueryResult(
      context: context,
      api: api,
      room: room,
      queryId: queryId,
      sessionId: sessionId,
      results: results,
      isCurrent: current,
    );
  } finally {
    api.dispose();
  }
}
