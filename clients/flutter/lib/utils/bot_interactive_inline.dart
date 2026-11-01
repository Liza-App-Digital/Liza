import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:liza/utils/bot_callback.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_delivery.dart';

class BotInlineResult {
  final String id;
  final String title;
  final Map<String, dynamic> content;
  const BotInlineResult(this.id, this.title, this.content);
}

/// Владелец query — один composer (client/room/session/text/generation).
/// Каждый await перепроверяет поколение, включая создание query и выбор.
class BotInlineController extends ChangeNotifier {
  final BotInteractiveApi api;
  final String roomId;
  final String sessionId = newBotTapId();
  final SendBotInteractiveMessage send;
  BotInteractiveDelivery? _delivery;
  int _generation = 0;
  bool _disposed = false;
  Timer? _debounce;
  Timer? _poll;
  String? _queryId;
  DateTime? _expires;
  List<BotInlineResult> results = const [];
  bool loading = false;
  bool recognisedBot = false;
  bool sending = false;
  bool failed = false;

  BotInlineController({
    required this.api,
    required this.roomId,
    required this.send,
  });

  bool _current(int generation) =>
      !_disposed && api.isCurrent && generation == _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void update(String text) {
    final generation = ++_generation;
    _delivery?.invalidate();
    _delivery = null;
    _debounce?.cancel();
    _poll?.cancel();
    final oldQuery = _queryId;
    _queryId = null;
    if (oldQuery != null) unawaited(_cancel(oldQuery));
    results = const [];
    loading = false;
    failed = false;
    sending = false;
    recognisedBot = false;
    final match = RegExp(
      r'^@([A-Za-z0-9_]{1,64})\s([\s\S]{0,4096})$',
    ).firstMatch(text);
    if (match != null) {
      loading = true;
      _debounce = Timer(
        const Duration(milliseconds: 350),
        () => _create(generation, match[1]!, match[2]!),
      );
    }
    _notify();
  }

  Future<void> _cancel(String query) async {
    try {
      await api.request(
        'POST',
        '/liza/interactive/query/${Uri.encodeComponent(query)}/cancel',
        body: {'session_id': sessionId},
      );
    } catch (_) {
      /* Отмена best effort; TTL на сервере остаётся обязательным. */
    }
  }

  Future<void> _create(int generation, String username, String text) async {
    try {
      final bot = await api.resolve(username: username);
      if (!_current(generation)) return;
      if (bot == null || !bot.supportsInteractive) {
        loading = false;
        _notify();
        return;
      }
      recognisedBot = true;
      final created = await api.request(
        'POST',
        '/liza/interactive/query',
        body: {
          'bot_mxid': bot.mxid,
          'room_id': roomId,
          'session_id': sessionId,
          'kind': 'inline',
          'query': text,
          'offset': '',
        },
      );
      final id = created['query_id'];
      if (id is! String) throw const FormatException();
      if (!_current(generation)) {
        unawaited(_cancel(id));
        return;
      }
      _queryId = id;
      final rawExpiry = created['expires_at'];
      _expires = rawExpiry is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (rawExpiry * (rawExpiry < 100000000000 ? 1000 : 1)).toInt(),
            )
          : DateTime.tryParse(rawExpiry is String ? rawExpiry : '');
      if (_expires == null) throw const FormatException();
      await _read(generation, id);
    } catch (_) {
      if (!_current(generation)) return;
      failed = true;
      loading = false;
      _notify();
    }
  }

  Future<void> _read(int generation, String id) async {
    if (!_current(generation)) return;
    if (_expires == null || !DateTime.now().isBefore(_expires!)) {
      results = const [];
      loading = false;
      _notify();
      return;
    }
    try {
      final response = await api.request(
        'GET',
        '/liza/interactive/query/${Uri.encodeComponent(id)}',
        query: {'session_id': sessionId},
      );
      if (!_current(generation)) return;
      final status = response['status'];
      if (status == 'pending') {
        _poll = Timer(
          const Duration(milliseconds: 600),
          () => _read(generation, id),
        );
        return;
      }
      loading = false;
      final raw = response['results'];
      results = status == 'answered' && raw is List
          ? [
              for (final item in raw.take(50))
                if (item is Map &&
                    item['id'] is String &&
                    item['title'] is String &&
                    safeInlineContent(item['content']) != null)
                  BotInlineResult(
                    item['id'] as String,
                    item['title'] as String,
                    safeInlineContent(item['content'])!,
                  ),
            ]
          : const [];
      _notify();
    } catch (_) {
      if (!_current(generation)) return;
      failed = true;
      loading = false;
      _notify();
    }
  }

  Future<bool> choose(BotInlineResult result) async {
    final generation = _generation;
    final id = _queryId;
    if (sending ||
        id == null ||
        !results.contains(result) ||
        !_current(generation) ||
        _expires == null ||
        !DateTime.now().isBefore(_expires!)) {
      return false;
    }
    sending = true;
    _notify();
    try {
      final existing = _delivery;
      if (existing != null && existing.resultId != result.id) return false;
      final delivery = _delivery ??= BotInteractiveDelivery(
        api: api,
        queryId: id,
        sessionId: sessionId,
        resultId: result.id,
        isCurrent: () =>
            _current(generation) &&
            _expires != null &&
            DateTime.now().isBefore(_expires!),
        allowAck: () => !_disposed && api.isCurrent,
        send: send,
      );
      // После выбора сервер фиксирует результат. На ошибке предлагаем повторить
      // именно его; выбор соседнего результата потребует нового query.
      results = [result];
      final success = await delivery.deliver();
      if (!_current(generation)) return false;
      if (success) {
        _queryId = null;
        results = const [];
        failed = false;
      } else {
        failed = true;
      }
      return success;
    } finally {
      if (_current(generation)) {
        sending = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _delivery?.invalidate();
    ++_generation;
    _debounce?.cancel();
    _poll?.cancel();
    final id = _queryId;
    if (id != null) {
      unawaited(_cancel(id).whenComplete(api.dispose));
    } else {
      api.dispose();
    }
    super.dispose();
  }
}
