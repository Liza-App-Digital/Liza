import 'package:liza/utils/bot_callback.dart';
import 'package:liza/utils/bot_interactive_api.dart';

typedef SendBotInteractiveMessage =
    Future<String?> Function(Map<String, dynamic> content, String txid);

/// Одна выбранная отправка. Повтор ошибки send использует прежний txid;
/// после получения event ID повторяется только ACK, без второго сообщения.
class BotInteractiveDelivery {
  final BotInteractiveApi api;
  final String queryId;
  final String sessionId;
  final String resultId;
  final bool Function() isCurrent;

  /// Отдельная жизнь ACK: смена текста может сохранить право подтверждения,
  /// но закрытие владельца запрещает его сразу, не дожидаясь HTTP cancel.
  final bool Function()? allowAck;
  final SendBotInteractiveMessage send;
  final String txid = 'bot-inline-${newBotTapId()}';
  String? _selectionId;
  Map<String, dynamic>? _content;
  String? eventId;
  bool completed = false;
  bool _invalid = false;
  bool _busy = false;

  BotInteractiveDelivery({
    required this.api,
    required this.queryId,
    required this.sessionId,
    required this.resultId,
    required this.isCurrent,
    this.allowAck,
    required this.send,
  });

  bool get current => !_invalid && api.isCurrent && isCurrent();
  void invalidate() => _invalid = true;

  Future<bool> deliver() async {
    if (!current || _busy) return false;
    if (completed) return true;
    _busy = true;
    try {
      if (_selectionId == null) {
        final selected = await api.request(
          'POST',
          '/liza/interactive/query/${Uri.encodeComponent(queryId)}/select',
          body: {'session_id': sessionId, 'result_id': resultId},
        );
        if (!current) return false;
        final content = safeInlineContent(selected['content']);
        final selectionId = selected['selection_id'];
        if (content == null || selectionId is! String || selectionId.isEmpty) {
          return false;
        }
        _content = content;
        _selectionId = selectionId;
      }
      if (!current) return false;
      if (eventId == null) {
        final sent = await send(Map.of(_content!), txid);
        if (sent == null || sent.isEmpty) return false;
        // Факт отправки сохраняется даже при уходе со страницы во время await.
        // Инвалидированная операция больше не вызывает send повторно.
        eventId = sent;
      }
      // Новое поколение запрещает новый send, но уже отправленное сообщение
      // подтверждаем в исходном query. Смена аккаунта/dispose запрещает и ACK.
      if (!api.isCurrent || !(allowAck?.call() ?? current)) return false;
      await api.request(
        'POST',
        '/liza/interactive/query/${Uri.encodeComponent(queryId)}/ack',
        body: {
          'session_id': sessionId,
          'selection_id': _selectionId,
          'event_id': eventId,
        },
      );
      completed = true;
      return true;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }
}
