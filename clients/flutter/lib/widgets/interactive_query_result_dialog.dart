import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_delivery.dart';

/// Диалог не закрывается на временной ошибке send/ACK: выбранная доставка
/// сохраняется, следующий тап продолжает её с тем же Matrix transaction ID.
class InteractiveQueryResultDialog extends StatefulWidget {
  final BotInteractiveApi api;
  final String queryId;
  final String sessionId;
  final List results;
  final bool Function() isCurrent;
  final SendBotInteractiveMessage send;
  const InteractiveQueryResultDialog({
    required this.api,
    required this.queryId,
    required this.sessionId,
    required this.results,
    required this.isCurrent,
    required this.send,
    super.key,
  });
  @override
  State<InteractiveQueryResultDialog> createState() =>
      _InteractiveQueryResultDialogState();
}

class _InteractiveQueryResultDialogState
    extends State<InteractiveQueryResultDialog> {
  BotInteractiveDelivery? _delivery;
  bool _busy = false;
  bool _failed = false;

  Future<void> _choose(String resultId) async {
    if (_busy || !widget.isCurrent()) return;
    if (_delivery != null && _delivery!.resultId != resultId) return;
    final delivery = _delivery ??= BotInteractiveDelivery(
      api: widget.api,
      queryId: widget.queryId,
      sessionId: widget.sessionId,
      resultId: resultId,
      isCurrent: () => mounted && widget.isCurrent(),
      send: widget.send,
    );
    setState(() {
      _busy = true;
      _failed = false;
    });
    final sent = await delivery.deliver();
    if (!mounted || !widget.isCurrent()) return;
    if (sent) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failed = true;
    });
  }

  @override
  void dispose() {
    _delivery?.invalidate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SimpleDialog(
    title: Text(L10n.of(context).botInlineResults),
    children: [
      if (_busy) const LinearProgressIndicator(),
      if (_failed)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(L10n.of(context).botInteractiveFailed),
        ),
      for (final result in widget.results)
        if (result is Map &&
            result['id'] is String &&
            safeInlineContent(result['content']) != null)
          SimpleDialogOption(
            onPressed:
                _busy ||
                    (_delivery != null && _delivery!.resultId != result['id'])
                ? null
                : () => _choose(result['id'] as String),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(safeInlineContent(result['content'])!['body'] as String),
                if (_failed && _delivery?.resultId == result['id'])
                  Text(L10n.of(context).tryToSendAgain),
              ],
            ),
          ),
    ],
  );
}
