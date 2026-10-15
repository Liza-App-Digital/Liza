import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/miniapp_room.dart';

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
