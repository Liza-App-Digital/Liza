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
/// пустой правой панели.
Future<void> openNewLizaRequest(BuildContext context) async {
  final client = Matrix.of(context).client;
  final title = L10n.of(context).newLizaRequest;
  final created = await showFutureLoadingDialog(
    context: context,
    future: () =>
        startLizaRequestChat(client, MatrixState.lizaMxid, title: title),
  );
  final result = created.result;
  if (result == null || !context.mounted) return;
  context.go('/rooms/${result.$1}');
}
