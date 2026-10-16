import 'package:matrix/matrix.dart';

import 'package:liza/utils/chat_topology.dart';

/// Может ли пользователь создавать чаты и подпространства в [space]: право
/// писать `m.space.child`. Тот же гейт держит кнопку «Создать чат» и пункт
/// «Новое подпространство» на экране компании.
bool canCreateChatInSpace(Room? space) =>
    space?.canChangeStateEvent(EventTypes.SpaceChild) == true;

/// Создать группу [name] внутри пространства [space] (кнопка «Создать чат» на
/// экране компании или подпространства) и вернуть её id.
///
/// Порог приглашения `invite: 50` ([groupPowerLevelOverride]) обязателен тем же
/// образом, что и в меню «+» (`new_group.dart` `_createGroup`): preset
/// `private_chat` Synapse выставляет `invite: 0`, и без override любой участник
/// группы компании приглашал посторонних. Фикс 25.08 закрыл только путь меню,
/// этот путь его не получил — рецидив, поэтому логика вынесена сюда и стережётся
/// юнит-тестом по телу запроса (`space_view` в widget-тесте не поднимается).
///
/// Ровно один родитель — место создания. `single_space_guard` решает, вкладывать
/// ли группу в главное пространство, на `m.room.create` — по маркеру, который он
/// сам ставит, если в `initial_state` есть `m.space.parent`. Поэтому родитель
/// объявляется при создании, а не после: прежний `setSpaceChild` приходил
/// позже, и группа из подпространства получала второй входящий `m.space.child`
/// от главного пространства (всплывала в корне компании). Связь со стороны
/// родителя пишется ОДНИМ `m.space.child`, как в `createSubspace`:
/// `Room.setSpaceChild` вторым PUT переписал бы уже имеющийся `m.space.parent`.
/// `via` — домен пользователя (SDK отсеивает связи с пустым `via`).
///
/// Если `m.space.child` не записался, группа покидается и забывается: с
/// родителем в `initial_state` сервер её в компанию уже не вложит, и она
/// осталась бы сиротой вне любого пространства. Исходная ошибка пробрасывается.
///
/// `waitForSync: false` — экран компании после создания перечитывает иерархию с
/// сервера (`_loadHierarchy`), локальная комната ему не нужна. `groupCall` не
/// передаётся: SDK дописал бы в override ключ `events` и снёс бы шаблонный блок.
///
/// [avatarUrl] и [enableEncryption] передаёт экран «Создать группу» при выборе
/// места (задача 10); кнопка на экране компании их не задаёт.
Future<String> createGroupInSpace({
  required Room space,
  required String name,
  Uri? avatarUrl,
  bool enableEncryption = false,
}) async {
  final client = space.client;
  final via = [client.userID!.domain!];

  final roomId = await client.createGroupChat(
    enableEncryption: enableEncryption,
    groupName: name,
    preset: CreateRoomPreset.privateChat,
    visibility: Visibility.private,
    waitForSync: false,
    powerLevelContentOverride: groupPowerLevelOverride(),
    initialState: [
      StateEvent(
        type: EventTypes.SpaceParent,
        stateKey: space.id,
        content: {'via': via},
      ),
      if (avatarUrl != null)
        StateEvent(
          type: EventTypes.RoomAvatar,
          content: {'url': avatarUrl.toString()},
        ),
    ],
  );
  try {
    await client.setRoomStateWithKey(space.id, EventTypes.SpaceChild, roomId, {
      'via': via,
    });
  } catch (e, s) {
    Logs().w('createGroupInSpace: $roomId не привязана к ${space.id}', e, s);
    try {
      await client.leaveRoom(roomId);
      await client.forgetRoom(roomId);
    } catch (e, s) {
      Logs().w(
        'createGroupInSpace: orphan $roomId left behind after failed m.space.child',
        e,
        s,
      );
    }
    rethrow;
  }
  return roomId;
}

/// Место, где можно создать группу: компания или её подпространство.
class GroupPlace {
  const GroupPlace({required this.space, this.company});

  final Room space;

  /// Компания-корень, если [space] — подпространство (для подписи).
  final Room? company;
}

/// Места для выбора «Где создать» на экране «Создать группу» (задача 10
/// newInterface): пространства, где пользователь состоит и может писать
/// `m.space.child`. Только такие: без права PUT `m.space.child` не пройдёт, и
/// через `parent_grace_seconds` `single_space_guard` вложит группу в главное
/// пространство сервера создателя — не туда, куда выбрали.
///
/// Порядок: компании по имени, за каждой — её подпространства обходом
/// `m.space.child` в глубину; места, до которых обход не дошёл (компания-корень
/// клиенту не видна), — в конце.
List<GroupPlace> groupPlaces(Iterable<Room> rooms) {
  final joinedSpaces = [
    for (final r in rooms)
      if (r.isSpace && r.membership == Membership.join) r,
  ];
  final byId = {for (final s in joinedSpaces) s.id: s};
  final eligible = {
    for (final s in joinedSpaces)
      if (canCreateChatInSpace(s)) s.id,
  };
  String name(Room r) => r.getLocalizedDisplayname();
  final roots =
      joinedSpaces
          .where((s) => isCompanySpace(space: s, allRooms: joinedSpaces))
          .toList()
        ..sort(
          (a, b) => name(a).toLowerCase().compareTo(name(b).toLowerCase()),
        );

  final result = <GroupPlace>[];
  final visited = <String>{};
  void walk(Room space, Room? company) {
    if (!visited.add(space.id)) return;
    if (eligible.contains(space.id)) {
      result.add(GroupPlace(space: space, company: company));
    }
    for (final child in space.spaceChildren) {
      final sub = byId[child.roomId];
      if (sub != null) walk(sub, company ?? space);
    }
  }

  for (final root in roots) {
    walk(root, null);
  }
  for (final s in joinedSpaces) {
    if (eligible.contains(s.id) && !visited.contains(s.id)) {
      visited.add(s.id);
      result.add(GroupPlace(space: s));
    }
  }
  return result;
}

/// Показывать ли выбор «Где создать» (Надежда 15.10): «Если пользователь
/// состоит и там, и там — показывать: создать в компании или для себя в общем
/// пространстве… Если пользователь состоит в компании и больше нигде, то по
/// сути у него нет выбора».
///
/// [companyInstance] — класс домашнего сервера: `false` общий (user.liza.ru,
/// там «Автоматически» = группа вне пространств, «для себя»), `true` компания
/// («Автоматически» = главное пространство своей компании), `null` — сервер
/// ещё не ответил: прежняя формула, не хуже, чем было.
///
/// На компании выбор нужен, только если есть место ВНЕ своей компании (её
/// корень — [ownCompanyRootId]): свои подпространства — то же «в компании».
bool shouldShowPlacePicker({
  required List<GroupPlace> places,
  required bool? companyInstance,
  required String? ownCompanyRootId,
  required String? userDomain,
}) {
  if (companyInstance == null) return places.length > 1;
  if (!companyInstance) return places.isNotEmpty;
  bool isOwn(GroupPlace p) {
    final rootId = (p.company ?? p.space).id;
    if (ownCompanyRootId != null) return rootId == ownCompanyRootId;
    return rootId.split(':').skip(1).join(':') == userDomain;
  }

  return places.any((p) => !isOwn(p));
}
