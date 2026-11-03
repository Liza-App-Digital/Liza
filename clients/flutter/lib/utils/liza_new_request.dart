import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/composer_draft.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/utils/new_request_transition.dart';
import 'package:liza/widgets/matrix.dart';

/// «Новый запрос»: открывает окно ввода запроса («Какую задачу решим?»), чат
/// создаётся уже при отправке (`sendNewLizaRequest`). Заявка Надежды 02.11:
/// и «+ Новый запрос» в меню шапки, и строка внизу списка чатов вели сразу в
/// пустой чат. Компьютер — пустая правая панель `/rooms`; узкий экран —
/// отдельный маршрут с кнопкой «назад».
void openNewLizaRequest(BuildContext context) {
  if (LizaThemes.isColumnMode(context)) {
    context.go('/rooms');
  } else {
    context.push(AppRoutes.newRequest);
  }
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
  NewRequestTransition.arm(roomId);
  router.go('/rooms/$roomId');
  return true;
}
