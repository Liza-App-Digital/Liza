import 'package:flutter/material.dart';

import 'package:collection/collection.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/widgets/future_loading_dialog.dart';

/// State-событие комнаты-запроса к Лизе («+» → «Новый запрос»). Ставится в
/// `initialState` при создании; `placeholder` — начальное имя комнаты: бот
/// `liza.py` переименует комнату в «Лиза: <суть>» только пока имя равно ему.
/// Тип внесён в `importantStateEvents` (client_manager.dart) — иначе после
/// холодного старта partial-комната вернула бы getState=null.
const String lizaRequestStateType = 'com.liza.assistant.request';

/// Комната — отдельный запрос к Лизе, а не её основной чат.
bool isLizaRequestRoom(Room room) =>
    room.getState(lizaRequestStateType) != null;

/// Живая 1:1-комната с ассистентом Лизой.
///
/// Ищем по MEMBER-стейту, а НЕ по `directChatMatrixID`: последний выводится из
/// m.direct, а именно его запись могла не создаться (сетевой сбой после
/// `startDirectChat` / стухший кеш) — тогда поиск промахнулся бы и появился второй
/// DM. Мёртвый `@liza:synapse...` DM (партнёр leave) под условие не подходит.
/// mini App-чат исключаем по непустому имени, запрос — по маркеру (его имя
/// человек может стереть): ассистент — @liza-DM без m.room.name и без маркера.
Room? findLizaAssistantDm(Client client, String lizaMxid) =>
    client.rooms.firstWhereOrNull(
      (r) =>
          !r.isSpace &&
          !isLizaRequestRoom(r) &&
          (r.getState(EventTypes.RoomName)?.content.tryGet<String>('name') ??
                  '')
              .isEmpty &&
          r
                  .getState(EventTypes.RoomMember, lizaMxid)
                  ?.content
                  .tryGet<String>('membership') ==
              'join',
    );

/// Живой личный чат с ботом [botMxid] (BotFather): я и бот в комнате, кроме
/// нас никого. По member-стейту, а не `getDirectChatFromUserId`: тот вернёт и
/// брошенный DM, где бот уже вышел, — команда ушла бы в пустоту.
Room? findBotDm(Client client, String botMxid) => client.rooms
    .where(
      (r) =>
          !r.isSpace &&
          r.membership == Membership.join &&
          (r.summary.mJoinedMemberCount ?? 0) +
                  (r.summary.mInvitedMemberCount ?? 0) ==
              2 &&
          r
                  .getState(EventTypes.RoomMember, botMxid)
                  ?.content
                  .tryGet<String>('membership') ==
              'join',
    )
    .sortedBy<num>(
      (r) => -(r.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0),
    )
    .firstOrNull;

/// Ждёт, пока [userId] вступит в комнату. Нужна свежему DM с ботом: событие,
/// отправленное до его join, бот увидит вперемешку с историей и приветствием.
Future<bool> waitForMemberJoin(
  Client client,
  String roomId,
  String userId, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  bool joined() =>
      client
          .getRoomById(roomId)
          ?.getState(EventTypes.RoomMember, userId)
          ?.content
          .tryGet<String>('membership') ==
      'join';

  final deadline = DateTime.now().add(timeout);
  while (!joined()) {
    if (!DateTime.now().isBefore(deadline)) {
      Logs().w('[LizaDm] $userId не вступил в $roomId за $timeout');
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return true;
}

/// Основной чат с Лизой: существующий или новый.
///
/// SDK `startDirectChat` без skipExistingChat берёт из m.direct самый СВЕЖИЙ DM
/// с Лизой — это может быть запрос или mini App-чат. Тогда основной не
/// пересоздался бы никогда, а `agent.start` ушёл бы в чужой запрос. Поэтому, если
/// SDK вернул бы не ассистента, создаём новый DM.
Future<String> ensureLizaAssistantDm(Client client, String lizaMxid) {
  final existing = findLizaAssistantDm(client, lizaMxid);
  if (existing != null) return Future.value(existing.id);
  final sdkPickId = client.getDirectChatFromUserId(lizaMxid);
  final sdkPick = sdkPickId == null ? null : client.getRoomById(sdkPickId);
  final forceNew = sdkPick != null && !isLizaAssistantRoom(sdkPick, lizaMxid);
  return client.ensureDirectChat(lizaMxid, forceNew: forceNew);
}

/// Новый отдельный чат-запрос к Лизе с именем [title] («Новый запрос»).
/// Возвращает id комнаты и вступила ли Лиза за таймаут (до её join первое
/// сообщение бот увидел бы вперемешку с историей).
Future<(String, bool)> startLizaRequestChat(
  Client client,
  String lizaMxid, {
  required String title,
}) async {
  final id = await client.ensureDirectChat(
    lizaMxid,
    forceNew: true,
    initialState: [
      StateEvent(type: lizaRequestStateType, content: {'placeholder': title}),
      StateEvent(type: EventTypes.RoomName, content: {'name': title}),
    ],
  );
  return (id, await waitForMemberJoin(client, id, lizaMxid));
}

/// Открывает основной чат с Лизой и нажимает в нём кнопку её карточки
/// [buttonId] (`agent.start` — мастер «Подключить своего агента»). Входы: пункт
/// «+» и кнопка `bf.agent` стартового меню BotFather.
///
/// Шлём callback кнопки (контракт карточек бота), а НЕ текст-фразу: на шаге
/// «название чата» мастер принял бы фразу за название и создал бота, а открытая
/// сессия подбора товара забрала бы её себе. Кнопка всегда начинает мастер
/// заново. [body] — человекочитаемый fallback события.
Future<void> openLizaAssistantWithCallback(
  BuildContext context,
  Client client,
  String lizaMxid, {
  required String buttonId,
  required String body,
}) async {
  var roomId = findLizaAssistantDm(client, lizaMxid)?.id;
  if (roomId == null) {
    final created = await showFutureLoadingDialog(
      context: context,
      future: () async {
        final id = await ensureLizaAssistantDm(client, lizaMxid);
        return (id, await waitForMemberJoin(client, id, lizaMxid));
      },
    );
    final result = created.result;
    if (result == null || !context.mounted) return;
    final (id, joined) = result;
    // Лиза не вступила за таймаут — callback пришёл бы ей вперемешку с
    // историей и приветствием; просто открываем чат, приветствие придёт само.
    if (!joined) {
      context.go('/rooms/$id');
      return;
    }
    roomId = id;
  }
  final errorText = L10n.of(context).oopsSomethingWentWrong;
  final messenger = ScaffoldMessenger.of(context);
  var sent = false;
  try {
    await client.getRoomById(roomId)?.sendEvent({
      'msgtype': 'com.liza.miniapp.callback',
      'body': body,
      'button_id': buttonId,
    });
    sent = true;
  } catch (e, s) {
    Logs().w('[LizaDm] $buttonId не отправлен', e, s);
  }
  // В чат переходим и при сбое, но не молча: без карточки пользователь иначе
  // решил бы, что кнопка не работает.
  if (!sent) messenger.showSnackBar(SnackBar(content: Text(errorText)));
  if (!context.mounted) return;
  context.go('/rooms/$roomId');
}
