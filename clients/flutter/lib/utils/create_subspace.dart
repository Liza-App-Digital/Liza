import 'package:matrix/matrix.dart';

import 'package:liza/utils/chat_topology.dart';

/// Создать подпространство [name] внутри пространства [parent] и вернуть его id.
///
/// Серверный модуль `single_space_guard` (`servers/synapse/modules/
/// single_space_guard/_guard.py`, `is_root_space_creation`) считает любой
/// `createRoom` с `creation_content.type = m.space` БЕЗ `m.space.parent` в
/// `initial_state` попыткой создать вторую компанию и отвечает 403 «Главное
/// пространство уже существует». SDK-обёртка `Client.createSpace` `initial_state`
/// не передаёт вовсе, поэтому прежний путь «createSpace → setSpaceChild»
/// падал на первом же шаге (LABA-2532). Здесь родитель объявляется сразу при
/// создании — ребёнок рождается с `m.space.parent`, гард его пропускает.
///
/// Затем связь пишется со стороны родителя ОДНИМ `m.space.child`: именно по
/// нему (а не по `m.space.parent`) строят иерархию и Synapse `/hierarchy`, и
/// клиент. `Room.setSpaceChild` не используется — он вторым запросом
/// переписал бы ребёнку тот самый `m.space.parent`, который у него уже есть.
///
/// `via` обязан быть непустым: SDK отсеивает связи с пустым `via`
/// (`Room.spaceParents`/`spaceChildren`) — сервер ответил бы 200, а в иерархии
/// подпространства не было бы. Источник тот же, что у `setSpaceChild`: домен
/// пользователя (его homeserver состоит в родителе, в т.ч. федеративном).
///
/// Если `m.space.child` не записался, созданное пространство best-effort
/// покидается и забывается: сервер space в компанию не авто-вкладывает
/// (`is_auto_add_candidate` отсекает `m.space`), а space без входящего
/// `m.space.child` клиент классифицирует как ВТОРУЮ СВОЮ КОМПАНИЮ
/// (`isTopLevelSpaceRoom` → `foreignCompanyKind == own`) — на rail появилась
/// бы фантомная компания с пунктом «Удалить компанию через поддержку».
///
/// `space_view` в widget-тесте не поднимается (общий гэп с `space_move.dart`),
/// поэтому логика живёт здесь и стережётся юнит-тестом по телам запросов.
///
/// [companyInstance] — подпространство компании этого инстанса (класс по
/// корню, `isOwnCompanySpace`): тогда приглашают только админы
/// ([spacePowerLevelOverride]), а админы и владельцы родителя переносятся в
/// подпространство уровнем 99 ([subspaceUsersOverride]) — иначе админ компании
/// в чужом подпространстве оказался бы рядовым и не мог бы приглашать. На
/// общем инстансе `users` не передаётся (Synapse: `{создатель: 100}`).
Future<String> createSubspace({
  required Room parent,
  required String name,
  required bool companyInstance,
}) async {
  final client = parent.client;
  final via = [client.userID!.domain!];

  final roomId = await client.createRoom(
    name: name,
    visibility: Visibility.private,
    creationContent: {'type': RoomCreationTypes.mSpace},
    powerLevelContentOverride: spacePowerLevelOverride(
      companyInstance: companyInstance,
      users: companyInstance
          ? subspaceUsersOverride(
              parentPowerLevels: parent
                  .getState(EventTypes.RoomPowerLevels)
                  ?.content,
              creatorId: client.userID!,
            )
          : null,
    ),
    initialState: [
      StateEvent(
        type: EventTypes.SpaceParent,
        stateKey: parent.id,
        content: {'via': via},
      ),
    ],
  );

  try {
    await client.setRoomStateWithKey(parent.id, EventTypes.SpaceChild, roomId, {
      'via': via,
    });
  } catch (_) {
    try {
      await client.leaveRoom(roomId);
      await client.forgetRoom(roomId);
    } catch (e, s) {
      Logs().w(
        'createSubspace: orphan $roomId left behind after failed m.space.child',
        e,
        s,
      );
    }
    rethrow;
  }
  return roomId;
}
