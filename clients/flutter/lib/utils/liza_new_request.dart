import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/composer_draft.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';

/// «Новый запрос»: отдельный чат с Лизой (P1 встречи 05.10). Название
/// «Liza: <суть>» ставит бот после первого сообщения; до того — «Новый
/// запрос». Двойной тап: барьер диалога + single-flight `forceNew`.
///
/// Вход для пункта «+» в шапке и строки внизу списка чатов: пустой чат, в
/// который Лиза пришлёт приглашение к задаче. `true` — чат открыт.
Future<bool> openNewLizaRequest(BuildContext context) async {
  final client = Matrix.of(context).client;
  final title = L10n.of(context).newLizaRequest;
  final created = await showFutureLoadingDialog(
    context: context,
    future: () async {
      final (id, _) = await startLizaRequestChat(
        client,
        MatrixState.lizaMxid,
        title: title,
      );
      return id;
    },
  );
  final roomId = created.result;
  if (roomId == null || !context.mounted) return false;
  context.go('/rooms/$roomId');
  return true;
}

/// Вопрос, набранный в пустой правой панели: чат открывается сразу, вопрос в
/// нём — первым сообщением (видео 22.10: «сразу открывается новый чат… его
/// запрос, как будто бы он отправил сообщение»). Без барьер-диалога и без
/// ожидания Лизы: «…» она покажет сама, когда вступит и начнёт отвечать.
///
/// Router и messenger берутся до await: при переходе окна через порог
/// двух колонок панель пересоздаётся, а начатый запрос должен дойти до чата.
/// `true` — чат открыт; `false` — комната не создана, текст остаётся в поле.
Future<bool> sendNewLizaRequest(BuildContext context, String text) async {
  final matrix = Matrix.of(context);
  final client = matrix.client;
  final store = matrix.store;
  final title = L10n.of(context).newLizaRequest;
  final errorText = L10n.of(context).oopsSomethingWentWrong;
  final router = GoRouter.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final String roomId;
  try {
    roomId = await createLizaRequestRoom(
      client,
      MatrixState.lizaMxid,
      title: title,
      firstMessage: true,
    );
  } catch (e, s) {
    Logs().w('[LizaRequest] чат-запрос не создан', e, s);
    messenger.showSnackBar(SnackBar(content: Text(errorText)));
    return false;
  }
  final room = client.getRoomById(roomId);
  if (room != null) {
    // Не ждём: локальное эхо и повтор при сбое — у SDK.
    room.sendTextEvent(text).catchError((Object e, StackTrace s) {
      Logs().w('[LizaRequest] вопрос в $roomId не отправлен', e, s);
      return null;
    });
  } else {
    // Комната создана, но ещё не пришла в sync — вопрос ждёт в поле ввода чата.
    try {
      await writeComposerDraft(store, roomId, text);
    } catch (e, s) {
      Logs().w('[LizaRequest] черновик вопроса в $roomId не сохранён', e, s);
    }
  }
  router.go('/rooms/$roomId');
  return true;
}
