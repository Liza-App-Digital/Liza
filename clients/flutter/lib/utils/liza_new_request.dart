import 'package:flutter/widgets.dart';

import 'package:go_router/go_router.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';

/// «Новый запрос»: отдельный чат с Лизой (P1 встречи 05.10). Название
/// «Лиза: <суть>» ставит бот после первого сообщения; до того — «Новый
/// запрос». Двойной тап: барьер диалога + single-flight `forceNew`.
///
/// Общая точка входа для пункта «+» в шапке, строки внизу списка чатов и
/// пустой правой панели. [initialMessage] — вопрос, набранный в пустой панели
/// до создания чата; уходит после приветствия Лизы
/// (`sendFirstRequestMessage`). `true` — чат открыт.
Future<bool> openNewLizaRequest(
  BuildContext context, {
  String? initialMessage,
}) async {
  final matrix = Matrix.of(context);
  final client = matrix.client;
  final store = matrix.store;
  final title = L10n.of(context).newLizaRequest;
  final created = await showFutureLoadingDialog(
    context: context,
    future: () async {
      final (id, joined) = await startLizaRequestChat(
        client,
        MatrixState.lizaMxid,
        title: title,
      );
      if (initialMessage != null) {
        await sendFirstRequestMessage(
          client,
          store,
          id,
          MatrixState.lizaMxid,
          initialMessage,
          lizaJoined: joined,
        );
      }
      return id;
    },
  );
  final roomId = created.result;
  if (roomId == null || !context.mounted) return false;
  context.go('/rooms/$roomId');
  return true;
}
