import 'package:matrix/matrix.dart';

import 'package:liza/utils/unseen_messages.dart';

const _legacyStoriesKey = 'com.liza.stories';
const _chatTypeKey = 'com.liza.chat.type';
const _topologyEventType = 'com.liza.chat.topology';

/// Room account data: «этот пользователь осознанно вступил в чат».
/// Именно account data, а не room-state: признак индивидуальный, и записать
/// его должен уметь подписчик с PL=0 (на state_default:50 он получил бы
/// M_FORBIDDEN, а запись state раскрыла бы чат сразу всем участникам).
const chatRevealedAccountDataType = 'com.liza.chat.revealed';

const channelChatType = 'channel';
const channelDiscussionChatType = 'channel_discussion';

/// State-событие: владелец включил запрет копирования, пересылки и
/// сохранения контента (аналог Liza `noforwards`).
///
/// Префикс `channel.` — исторический: изначально настройка была только у
/// каналов. С 2026-08-12 событие используется и в групповых чатах, но имя
/// сохранено ради совместимости с уже существующими каналами, где флаг
/// включён. Переименование потребовало бы двойного чтения или бэкфилла.
const channelNoForwardsState = 'com.liza.channel.no_forwards';

/// State-событие: в комнате не показывать аватарки «прочитал до сюда».
/// Ставится operator'ом (`deploy/scripts/liza-news-setup.py --hide-receipts`)
/// в Liza News: подписчики не должны видеть, кто из пользователей Лизы читает.
/// Скрытие только в UI — сами m.receipt по-прежнему приходят в /sync.
///
/// Тип НАМЕРЕННО не в `importantStateEvents`: аватарки рисуются только в
/// открытом таймлайне, а `getTimeline()` делает `postLoad()` и подгружает
/// неважные состояния. Промоушен в important постфактум сделал бы значение,
/// уже принятое старыми сборками, нечитаемым (см. client_manager.dart).
const String hideReadReceiptsState = 'com.liza.chat.hide_read_receipts';

/// Роли в комнате (механика ВК, спека 2026-10-14-room-owner-role-design):
/// владелец — 100, администратор — 99, модератор — 50.
///
/// Владелец и администратор разведены на соседние уровни ради правила
/// протокола «менять можно только тех, кто ниже тебя»: владелец (100) снимает
/// админа (99), а админы не трогают ни владельца, ни друг друга (99 < 99 —
/// ложь). Предикат «админ» в клиенте — `>= adminPowerLevel`, он включает и
/// владельца. В старых комнатах может быть несколько 100 — это равные
/// со-владельцы, как было до введения роли.
const int ownerPowerLevel = 100;
const int adminPowerLevel = 99;
const int moderatorPowerLevel = 50;

bool isOwnerLevel(int powerLevel) => powerLevel >= ownerPowerLevel;

/// Максимальная роль, которую [ownPowerLevel] может выдать участнику.
/// Админа назначает только владелец; админ назначает не выше модератора.
int assignableRoleMaxLevel(int ownPowerLevel) =>
    ownPowerLevel >= ownerPowerLevel
    ? adminPowerLevel
    : (ownPowerLevel < moderatorPowerLevel
          ? ownPowerLevel
          : moderatorPowerLevel);

/// Верхняя граница значения порога [key] (в [category] или верхнего уровня),
/// которое [ownPowerLevel] может выставить на экране «Права».
///
/// `users_default` — это не порог действия, а роль КАЖДОГО участника по
/// умолчанию: 99 «Администратор» разом делала бы админом всех (в т.ч. новых),
/// и они смогли бы деактивировать участников через access_admin. Поэтому для
/// него потолок — модератор, даже у владельца (роль админа выдаётся только
/// поимённо). Остальные пороги — не выше собственного уровня и не выше 99:
/// «только админы» — законная настройка и для админа.
int permissionThresholdMaxLevel({
  required String key,
  String? category,
  required int ownPowerLevel,
}) {
  final cap = category == null && key == 'users_default'
      ? moderatorPowerLevel
      : adminPowerLevel;
  return ownPowerLevel < cap ? ownPowerLevel : cap;
}

/// Пороги, которые [normalizeOwnerModelThresholds] НЕ опускает до 99:
/// `com.liza.chat.topology` (скрытость/тип комнаты) держится только за
/// владельцем — на 100 опираются сторис (stories_extension.dart) и серверный
/// backfill скрытых комнат.
const Set<String> ownerOnlyEventThresholds = {_topologyEventType};

/// Копия content `m.room.power_levels`, где каждый порог, равный ровно
/// [ownerPowerLevel], опущен до [adminPowerLevel] (кроме
/// [ownerOnlyEventThresholds]).
///
/// Шаблон Synapse и override-ы создания держат «админские» пороги на 100
/// (`m.room.power_levels`, `history_visibility`, у канала `events_default`).
/// Админ-99 в такой комнате не смог бы назначать модераторов и публиковать в
/// канале. Поэтому пороги нормализуются в том же событии, которое впервые
/// выдаёт 99 ([promoteToAdminContent], [transferOwnershipContent]). Сделать это
/// вправе только тот, у кого PL >= старого порога, то есть владелец. Так одним
/// механизмом покрыты и новые комнаты, и созданные старыми сборками, и
/// пространства, чьи power_levels создаёт не наш override. `users` не трогаем.
Map<String, Object?> normalizeOwnerModelThresholds(
  Map<String, Object?> content,
) {
  int? lowered(Object? v) => v == ownerPowerLevel ? adminPowerLevel : null;
  final result = <String, Object?>{};
  for (final entry in content.entries) {
    final value = entry.value;
    if (entry.key == 'users') {
      result['users'] = value is Map ? Map<String, Object?>.from(value) : value;
    } else if (value is Map) {
      result[entry.key] = {
        for (final e in value.entries)
          e.key.toString():
              entry.key == 'events' &&
                  ownerOnlyEventThresholds.contains(e.key.toString())
              ? e.value
              : lowered(e.value) ?? e.value,
      };
    } else {
      result[entry.key] = lowered(value) ?? value;
    }
  }
  return result;
}

Map<String, Object?> _withUsers(
  Map<String, Object?> content,
  Map<String, int> changes,
) {
  final result = normalizeOwnerModelThresholds(content);
  final users = result['users'] is Map
      ? Map<String, Object?>.from(result['users'] as Map)
      : <String, Object?>{};
  users.addAll(changes);
  result['users'] = users;
  return result;
}

/// Тело ОДНОГО события `m.room.power_levels` «сделать администратором».
Map<String, Object?> promoteToAdminContent(
  Map<String, Object?> content,
  String targetId,
) => _withUsers(content, {targetId: adminPowerLevel});

/// Тело ОДНОГО события «передать владение»: получателю 100, себе 99.
/// Одним событием, а не двумя `setPower`: после первого (себе 99) отдать 100
/// уже нельзя — новое значение выше собственного уровня.
Map<String, Object?> transferOwnershipContent(
  Map<String, Object?> content, {
  required String ownerId,
  required String recipientId,
}) => _withUsers(content, {
  recipientId: ownerPowerLevel,
  ownerId: adminPowerLevel,
});

/// Отправить ОДНО событие `m.room.power_levels`, собранное [build] из
/// текущего content комнаты. Как и SDK `Room.setPower`, берём локальный state,
/// но без него НЕ шлём `{}`: пустой content стёр бы все пороги комнаты.
Future<String> _putOwnerModelPowerLevels(
  Room room,
  Map<String, Object?> Function(Map<String, Object?> current) build,
) async {
  final current = room.getState(EventTypes.RoomPowerLevels)?.content;
  if (current == null) {
    throw StateError('m.room.power_levels ещё не загружен в ${room.id}');
  }
  return await room.client.setRoomStateWithKey(
    room.id,
    EventTypes.RoomPowerLevels,
    '',
    build(Map<String, Object?>.from(current)),
  );
}

/// «Сделать администратором»: цели 99 + нормализация порогов, одним событием.
Future<String> promoteMemberToAdmin(Room room, String userId) =>
    _putOwnerModelPowerLevels(
      room,
      (current) => promoteToAdminContent(current, userId),
    );

/// «Передать владение»: получателю 100, себе 99, одним событием.
Future<String> transferRoomOwnership(Room room, String recipientId) =>
    _putOwnerModelPowerLevels(
      room,
      (current) => transferOwnershipContent(
        current,
        ownerId: room.client.userID!,
        recipientId: recipientId,
      ),
    );

/// Можно ли показать «Передать владение» на строке участника.
bool canTransferOwnershipTo({
  required int ownPowerLevel,
  required String callerId,
  required String targetId,
  required int targetPowerLevel,
  required bool targetJoined,
  required bool isDirectChat,
}) =>
    isOwnerLevel(ownPowerLevel) &&
    !isDirectChat &&
    callerId != targetId &&
    targetJoined &&
    !isServiceAccountId(targetId) &&
    targetPowerLevel < ownerPowerLevel;

/// State-событие: администратор (PL >= 99) скрыл участников из ВИТРИНЫ списка
/// участников (кнопка «Скрыть из списка», LABA-2381). Глобально: у всех членов
/// чата список рисуется без них. Скрытие косметическое — членство, сообщения,
/// права скрытого НЕ меняются, и себя он видит как обычно.
///
/// `state_key = ''` (единый список `user_ids`), а НЕ по одному событию на юзера
/// со `state_key = @victim`: Synapse (room v10/v11, `msc3757` off) отвергает
/// state event, чей state_key начинается с `@` и ≠ отправителя — `403 "You are
/// not allowed to set others state"` (`event_auth.py`). Пустой state_key этот
/// блок обходит; порог записи — `state_default` (50). Клиентский гейт PL>=99 —
/// сверх серверного 50 (осознанная модель доверия модератору, спека
/// `docs/superpowers/specs/2026-08-18-participant-hide-from-member-list-design.md`,
/// R1). Тип в `importantStateEvents` (client_manager.dart), иначе partial-
/// комната вернёт `getState=null` и скрытие молча отвалится.
const hiddenMembersState = 'com.liza.chat.hidden_members';

/// Шаблонные пороги `events`, которые Synapse проставляет новой комнате
/// по умолчанию (`handlers/room.py`, ветка сборки `power_level_content`).
///
/// ⚠️ Их обязан повторить ЛЮБОЙ `powerLevelContentOverride`, где есть ключ
/// `events`: сервер применяет override через shallow-merge
/// (`power_level_content.update(...)`), то есть заменяет `events` ЦЕЛИКОМ.
/// Не перечисленные здесь события проваливаются на `state_default: 50` —
/// и модератор канала (PL 50) получает право переписать `m.room.power_levels`,
/// то есть выдать себе админа, а заодно снять шифрование и history_visibility.
///
/// `m.room.tombstone` = 100, а не 150: 150 сервер ставит только комнатам с
/// `msc4289_creator_power_enabled` (версии `12` / `org.matrix.hydra.11`), а
/// инстансы Liza создают комнаты дефолтной версии `10`, где максимальный PL
/// создателя — 100. Порог 150 в такой комнате недостижим ни для кого и
/// намертво ломает апгрейд комнаты (`upgradeRoom` шлёт tombstone).
const Map<String, Object?> synapseDefaultEventPowerLevels = {
  'm.room.name': 50,
  'm.room.power_levels': 100,
  'm.room.history_visibility': 100,
  'm.room.canonical_alias': 50,
  'm.room.avatar': 50,
  'm.room.tombstone': 100,
  'm.room.server_acl': 100,
  'm.room.encryption': 100,
};

/// power_levels нового канала.
///
/// `events_default: 100` — постить может только админ (это и есть канал).
/// Порог `m.reaction: 0` обязателен явно: иначе он унаследует
/// `events_default`, и подписчику реакции запретит сервер.
///
/// Порог `m.room.redaction: 0` — ПАРНЫЙ к `m.reaction`: снятие реакции это
/// не «отмена», а отправка события `m.room.redaction`. Без явного порога оно
/// тоже наследует `events_default: 100`, и подписчик, поставивший реакцию,
/// получал `M_FORBIDDEN` при попытке её снять («Нет прав доступа»).
///
/// ⚠️ Именно `events['m.room.redaction'] = 0`, а НЕ `redact: 0`. Это разные
/// права по auth-rules Matrix: `events['m.room.redaction']` — право ОТПРАВИТЬ
/// событие редакции (по нему пользователь удаляет СВОЁ событие, ветка
/// «sender редакции == sender цели»), а `redact` — право отредактировать
/// ЧУЖОЕ событие. Опустив `redact` до 0, мы дали бы любому подписчику удалять
/// посты канала и чужие реакции; поэтому `redact` остаётся шаблонным (50).
///
/// Порог `invite: moderatorPowerLevel` (50) обязателен явно: preset
/// `private_chat`/`trusted_private_chat` Synapse выставляет `invite: 0`
/// (`handlers/room.py`), и без явного порога ПРИВАТНЫЙ канал наследовал 0 —
/// любой подписчик (PL 0) мог приглашать посторонних. Публичный канал (preset
/// `public_chat`) уже получал 50 из шаблона Synapse, приватный — нет; это
/// расхождение выравниваем, чтобы приглашать в канал мог только модератор,
/// независимо от типа (проверено на локальном стеке 2026-08-24,
/// [[RL-channel-permissions-enforcement]]).
///
/// Шаблонные пороги переносим явно — см. [synapseDefaultEventPowerLevels].
Map<String, Object?> channelPowerLevelOverride() => {
  'events_default': 100,
  'invite': moderatorPowerLevel,
  'events': {
    ...synapseDefaultEventPowerLevels,
    'm.reaction': 0,
    'm.room.redaction': 0,
  },
};

/// power_levels нового ГРУППОВОГО чата.
///
/// Задаёт ТОЛЬКО `invite: moderatorPowerLevel` (50). Preset `private_chat`
/// Synapse (`handlers/room.py`) выставляет `invite: 0`, и без явного порога
/// приватная группа наследовала 0 — любой участник (PL 0) мог приглашать
/// посторонних (тот же класс отклонения, что был у канала, см.
/// [channelPowerLevelOverride] и `howItWoks/chanels/rightsInChannel.md §6`).
/// Публичная группа (preset `public_chat`) уже получала 50 из шаблона Synapse —
/// расхождение выравниваем, чтобы приглашать в группу мог только модератор,
/// независимо от типа.
///
/// ⚠️ НАМЕРЕННО без ключа `events` и без `events_default`. Synapse применяет
/// override shallow-merge'ем top-level ключей: `invite` перекрывает preset-ный
/// `invite: 0`, НЕ трогая шаблонный блок `events`. Появись здесь ключ `events`
/// — он заменил бы весь блок ЦЕЛИКОМ (как в канале, где ради этого копируется
/// [synapseDefaultEventPowerLevels]), и неперечисленные типы упали бы на
/// `state_default: 50` → модератор группы переписал бы `m.room.power_levels`.
/// В отличие от канала, группе НЕЛЬЗЯ поднимать `events_default` до 100 — в
/// группе сообщения пишут ВСЕ участники (порог остаётся дефолтным 0).
Map<String, Object?> groupPowerLevelOverride() => {
  'invite': moderatorPowerLevel,
};

/// power_levels нового ПРОСТРАНСТВА (компания или подпространство).
///
/// `events_default: 100` — state пространства (дети, имя) пишет только админ.
///
/// `invite: adminPowerLevel` (99) — только на инстансе-компании
/// ([companyInstance], поле `company` ответа `single_space_guard`): «если в
/// настройках компании выбрано, что приглашать могут только админы — значит,
/// только админы. По умолчанию предлагаю именно так» (Надежда, 14.10, спека
/// 2026-10-14-search-sections-and-company-invite-admin-only). Preset
/// `private_chat` иначе даёт `invite: 0`, и приглашать мог любой участник.
/// 99, а не 100: админ (99) приглашает, а [normalizeOwnerModelThresholds]
/// такой порог не трогает. На общем инстансе (users.liza.ru, «компания сама по
/// себе общая») порог прежний — preset-ный.
///
/// Без ключа `events` — по той же причине, что [groupPowerLevelOverride].
///
/// [users] — поимённые уровни нового пространства (см.
/// [subspaceUsersOverride]). Synapse и этот ключ сливает shallow: переданный
/// `users` ЗАМЕНЯЕТ его `{создатель: 100}` целиком, поэтому создатель обязан
/// быть в карте (иначе 400 «'users' did not contain ...»).
Map<String, Object?> spacePowerLevelOverride({
  required bool companyInstance,
  Map<String, int>? users,
}) => {
  'events_default': 100,
  if (companyInstance) 'invite': adminPowerLevel,
  'users': ?users,
};

/// `users` нового подпространства компании: администраторы и владельцы
/// родителя (PL >= [adminPowerLevel]) переносятся с уровнем
/// min(их PL, [adminPowerLevel]), создатель — [ownerPowerLevel].
///
/// Без переноса подпространство на инстансе-компании (`invite: 99`) знало бы
/// одного создателя: админ компании получал бы в чужом подпространстве 0 и
/// видел ложную плашку «Приглашать могут только администраторы». Владелец
/// родителя — тоже 99, а не 100: владелец подпространства один — его
/// создатель (модель владельца, спека 2026-10-14-room-owner-role-design).
/// Рядовые участники и модераторы не переносятся — у них уровень по умолчанию.
Map<String, int> subspaceUsersOverride({
  required Map<String, Object?>? parentPowerLevels,
  required String creatorId,
}) {
  final parentUsers = parentPowerLevels?['users'];
  final result = <String, int>{};
  if (parentUsers is Map) {
    for (final e in parentUsers.entries) {
      final v = e.value;
      final level = v is num ? v.toInt() : int.tryParse('$v');
      if (level == null || level < adminPowerLevel) continue;
      result[e.key.toString()] = adminPowerLevel;
    }
  }
  result[creatorId] = ownerPowerLevel;
  return result;
}

/// Виден ли поимённый список людей: в пространстве и в канале — только
/// модератору/админу.
///
/// Отдельная чистая функция, чтобы правило было тестируемо без Room.
/// Специально НЕ зависит от порога `invite`: в пространствах-компаниях он
/// равен 0 (приглашать может любой участник), и гейт на `canInvite` не
/// отсекал бы никого — из-за этого обычный участник видел список людей.
///
/// В канале скрываем по той же причине: подписчику незачем видеть, кто ещё
/// подписан. ЧИСЛО подписчиков при этом остаётся видимым всем — это публичная
/// метрика канала.
bool canSeeMembersAt({
  required bool isSpace,
  required bool isChannel,
  required int ownPowerLevel,
}) => (!isSpace && !isChannel) || ownPowerLevel >= moderatorPowerLevel;

/// Скрыт ли участник [memberId] из ВИТРИНЫ списка для зрителя [viewerId].
///
/// Себя зритель видит ВСЕГДА: скрытого участника нельзя убрать из его же
/// списка — иначе меняется «поведение скрытого» (требование LABA-2381).
/// Отдельная чистая функция, чтобы правило было тестируемо без Room.
bool isMemberHiddenFor({
  required Set<String> hiddenIds,
  required String memberId,
  required String viewerId,
}) => memberId != viewerId && hiddenIds.contains(memberId);

/// Новый список скрытых после скрытия/возврата [userId]. Чистая функция
/// (read-before-write мерж), чтобы правило было тестируемо без сети: скрытие
/// добавляет id к текущему набору, возврат — убирает, соседей не трогая.
Set<String> nextHiddenMemberIds(
  Set<String> current,
  String userId, {
  required bool hidden,
}) {
  final next = <String>{...current};
  if (hidden) {
    next.add(userId);
  } else {
    next.remove(userId);
  }
  return next;
}

/// Может ли пользователь поставить реакцию.
///
/// Отдельное правило, потому что право слать `m.reaction` НЕ равно праву
/// слать сообщения: канал создаётся с `events_default: 100`, и гейт на
/// `canSendDefaultMessages` прятал реакции у всех подписчиков (регресс
/// 2026-07-28). Порог `m.reaction` при этом остаётся 0.
bool canReactAt({required int ownPowerLevel, required int reactionThreshold}) =>
    ownPowerLevel >= reactionThreshold;

/// Можно ли вообще взаимодействовать с реакциями в этой комнате.
///
/// Peek-лента канала (чтение без подписки) строится на комнате с
/// `Membership.leave`, и порог `m.reaction` там равен 0 — одного
/// [canReactAt] мало: тап отправил бы `m.reaction` от неучастника, сервер
/// ответил бы `M_FORBIDDEN`, а чип успел бы мигнуть «поставлено». По
/// продуктовому решению читатель без подписки реакции не ставит вовсе.
bool canInteractWithReactionsAt({required Membership membership}) =>
    membership == Membership.join;

/// Может ли пользователь СНЯТЬ собственную реакцию.
///
/// Снятие реакции — это отправка события `m.room.redaction`, у которого свой
/// порог. В канале (`events_default: 100`) без явного `events['m.room.redaction']`
/// порог наследуется от `events_default`, и сервер отвечает `M_FORBIDDEN`:
/// подписчик ставил реакцию, но не мог её убрать (баг 2026-08-01).
///
/// Считаем порог ОТПРАВКИ редакции, а не `redact`: `redact` — это право
/// редактировать ЧУЖОЕ событие, и подписчику оно не нужно и не должно быть
/// выдано. Своё собственное событие снимается по ветке auth-rules
/// «sender редакции == sender цели».
bool canRedactOwnAt({
  required int ownPowerLevel,
  required int redactionThreshold,
}) => ownPowerLevel >= redactionThreshold;

/// Закрыт ли контент комнаты для копирования, пересылки, сохранения и share.
///
/// Работает и в каналах, и в групповых чатах: предикат зависит только от флага
/// и от power level, тип комнаты не учитывается.
///
/// Скриншоты блокируются ЧАСТИЧНО и зависят от платформы (см.
/// `utils/secure_screen.dart`): Android — `FLAG_SECURE` (скриншот и запись
/// экрана запрещены); macOS — запись/шаринг окна запрещены, скриншот нет;
/// iOS — только блюр в переключателе приложений; web/Windows/Linux — ничего.
///
/// Модераторы и администраторы (PL >= 50) не ограничиваются: иначе владелец не
/// смог бы скопировать собственный пост, а модератор — работать с контентом,
/// который он же и модерирует.
///
/// Это UX-барьер, а не защита контента: содержимое покажет любой сторонний
/// Matrix-клиент, а экран можно снять другим устройством.
bool contentProtected({required bool noForwards, required int ownPowerLevel}) =>
    noForwards && ownPowerLevel < moderatorPowerLevel;

/// Является ли [space] корневым пространством-компанией, а не суб-
/// пространством внутри чьей-то компании.
///
/// НЕ использует `Room.spaceParents`: SDK прямо предупреждает, что
/// канонический флаг не проставляется и обратная связь ребёнок→родитель не
/// гарантирована (`matrix` package, `room.dart` — `spaceParents`), а у комнат,
/// вложенных в компанию СЕРВЕРОМ (`single_space_guard` пишет только
/// `m.space.child`), события `m.space.parent` нет вовсе. Что оно есть у
/// подпространств, созданных клиентом (`create_subspace.dart`, LABA-2532) и
/// у детей `setSpaceChild()` SDK 4.1, — недостаточно: классификация обязана
/// работать и для серверной привязки. Поэтому «компания» определяется
/// достоверно ТОЛЬКО обратным обходом: [space] не является дочерней ни для
/// одного известного клиенту пространства из [allRooms].
/// Иначе — не риск ошибочного «Админ компании» в суб-пространстве, а более
/// общая, но верная классификация «пространство».
bool isCompanySpace({required Room space, required Iterable<Room> allRooms}) {
  if (!space.isSpace) return false;
  final isChildOfSomeSpace = allRooms.any(
    (r) =>
        r.isSpace &&
        r.id != space.id &&
        r.spaceChildren.any((c) => c.roomId == space.id),
  );
  return !isChildOfSomeSpace;
}

/// Сервисные аккаунты (боты/поддержка), которым НЕЛЬЗЯ передавать канал при
/// выходе единственного админа: бот получит PL100, но Liza-UI никогда не покажет
/// ему кнопку управления каналом → канал осиротеет навсегда (KILLER-возражение
/// комиссии). Сверка по localpart, домен бота (`bots.liza.ru`) не завязываем —
/// боты живут и на инстансах-компаниях.
const Set<String> serviceAccountLocalparts = {
  'liza',
  'gpt',
  'deepseek',
  'support',
};

/// Является ли [userId] сервисным аккаунтом (бот/поддержка).
bool isServiceAccountId(String userId) {
  final localpart = userId.split(':').first.replaceFirst('@', '');
  return serviceAccountLocalparts.contains(localpart);
}

/// Кандидат-преемник админа при выходе единственного администратора канала.
class ChannelSuccessorCandidate {
  final String id;
  final int powerLevel;
  const ChannelSuccessorCandidate(this.id, this.powerLevel);
}

/// Выбор преемника-админа среди УЖЕ отфильтрованных кандидатов (join, не я, не
/// сервисный, не скрытый). Приоритет — модератор (PL>=50) с максимальным PL
/// (по тексту тикета «приоритетно модератор»), иначе первый по id.
///
/// «Рандом» из тикета заменён детерминированным выбором (первый по id): любой
/// участник годится, а детерминизм делает правило тестируемым без флаки.
/// Возвращает `null`, если кандидатов нет (тогда канал единственного участника
/// удаляется).
String? pickChannelSuccessor(Iterable<ChannelSuccessorCandidate> candidates) {
  final list = candidates.toList();
  if (list.isEmpty) return null;
  final moderators =
      list.where((c) => c.powerLevel >= moderatorPowerLevel).toList()
        ..sort((a, b) => b.powerLevel.compareTo(a.powerLevel));
  if (moderators.isNotEmpty) return moderators.first.id;
  list.sort((a, b) => a.id.compareTo(b.id));
  return list.first.id;
}

/// Стандартный `room_type`, которым сервер (модуль channel_guard) помечает
/// канал при создании. Нужен там, где доступен только ответ /publicRooms:
/// он не отдаёт `com.liza.chat.type`, поэтому иначе канал неотличим от чата.
const lizaChannelRoomType = 'com.liza.channel';

/// Единый хелпер топологии чата: тип комнаты (`com.liza.*`) и её видимость
/// в основном списке чатов. Заменяет точечные проверки
/// `creation_content['com.liza.stories']` по всему клиенту.
extension LizaChatTopology on Room {
  /// Тип Liza-чата по `m.room.create` content: `'stories'` либо `null` для
  /// обычных комнат. Новый ключ `com.liza.chat.type` имеет приоритет над
  /// легаси-ключом `com.liza.stories`.
  String? get lizaChatType {
    final createContent = getState(EventTypes.RoomCreate)?.content;
    if (createContent == null) return null;

    final explicitType = createContent[_chatTypeKey];
    if (explicitType is String) return explicitType;

    if (createContent[_legacyStoriesKey] == true) return 'stories';

    return null;
  }

  /// Раскрыл ли ТЕКУЩИЙ пользователь эту комнату персонально (нажал
  /// «Обсуждение»). Личный флаг в room account data — у каждого свой.
  bool get isRevealedByMe =>
      roomAccountData[chatRevealedAccountDataType]?.content['revealed'] == true;

  /// Скрыта ли комната из основного списка чатов.
  ///
  /// Персональное раскрытие сильнее общей скрытости: room-state
  /// `com.liza.chat.topology` = `hidden:true` — это «скрыто по умолчанию у
  /// всех», а осознавший вход подписчик снимает скрытость только себе.
  /// Легаси сторис-комнаты без бэкфилленного topology state считаются
  /// скрытыми по умолчанию.
  ///
  /// ⚠️ Это КЛИЕНТСКИЙ фильтр, и он не единственный. На проде включён модуль
  /// `chat_topology_sync_gate`: устройству, не прошедшему version-gate (в
  /// частности Web — он не шлёт build number, см. `device_capability_service`),
  /// сервер вырезает hidden-комнаты из `/sync` целиком. Там `revealed` не
  /// учитывается — модуль читает только room-state. Значит на таком клиенте
  /// персонально раскрытая комната всё равно не появится: её просто нет в sync.
  bool get isHiddenChat {
    if (isRevealedByMe) return false;

    final topologyContent = getState(_topologyEventType)?.content;
    if (topologyContent != null) {
      return topologyContent['hidden'] == true;
    }

    return lizaChatType == 'stories';
  }

  /// Персонально показать комнату в списке чатов (осознанный вход в
  /// обсуждение). Пишет room account data — доступно пользователю с любым PL.
  Future<void> revealChatForMe() => client.setAccountDataPerRoom(
    client.userID!,
    id,
    chatRevealedAccountDataType,
    {'revealed': true},
  );

  /// Является ли комната каналом типа 'channel'.
  bool get isChannel => lizaChatType == channelChatType;

  /// Является ли комната привязанным чатом-обсуждением канала.
  bool get isChannelDiscussion => lizaChatType == channelDiscussionChatType;

  /// Владелец комнаты включил запрет копирования/пересылки/сохранения.
  bool get noForwards =>
      getState(channelNoForwardsState)?.content.tryGet<bool>('enabled') ??
      false;

  /// Скрывать ли аватарки прочитавших (true только при bool `enabled: true`).
  /// Читать только в открытом чате — см. [hideReadReceiptsState].
  bool get hideReadReceipts =>
      getState(hideReadReceiptsState)?.content.tryGet<bool>('enabled') ?? false;

  /// Действует ли запрет на ТЕКУЩЕГО пользователя. В комнате без state
  /// `com.liza.channel.no_forwards` — всегда `false`.
  bool get isContentProtected =>
      contentProtected(noForwards: noForwards, ownPowerLevel: ownPowerLevel);

  /// Доступен ли поимённый список участников (база юзеров пространства либо
  /// состав подписчиков канала).
  ///
  /// Скрытие в UI, НЕ защита: членство комнаты Matrix отдаёт её участникам
  /// в любом случае.
  bool get canSeeSpaceMembers => canSeeMembersAt(
    isSpace: isSpace,
    isChannel: isChannel,
    ownPowerLevel: ownPowerLevel,
  );

  /// Множество user_id, скрытых из витрины списка участников (room state
  /// [hiddenMembersState]). Пусто, если события нет.
  Set<String> get hiddenMemberIds {
    final ids = getState(
      hiddenMembersState,
    )?.content.tryGetList<String>('user_ids');
    return ids == null ? const <String>{} : ids.toSet();
  }

  /// Вправе ли ТЕКУЩИЙ пользователь скрывать/возвращать участников
  /// (владелец/админ). Серверный порог записи ниже (`state_default`=50), но
  /// кнопку показываем только админу (PL>=99) — по тексту тикета «функция админа».
  bool get canHideMembers => ownPowerLevel >= adminPowerLevel;

  /// Скрыт ли [memberId] из витрины списка для ТЕКУЩЕГО пользователя.
  bool isMemberHiddenForMe(String memberId) => isMemberHiddenFor(
    hiddenIds: hiddenMemberIds,
    memberId: memberId,
    viewerId: client.userID ?? '',
  );

  /// Отфильтровать участников для витрины списка: убрать скрытых (кроме себя).
  /// ЕДИНАЯ точка для ОБЕИХ витрин (экран участников + превью деталей чата),
  /// чтобы скрытый не всплыл где-то мимо фильтра.
  Iterable<User> visibleParticipants(Iterable<User> participants) {
    final hidden = hiddenMemberIds;
    if (hidden.isEmpty) return participants;
    final me = client.userID ?? '';
    return participants.where(
      (u) =>
          !isMemberHiddenFor(hiddenIds: hidden, memberId: u.id, viewerId: me),
    );
  }

  /// Скрыть/вернуть участника в витрине списка.
  ///
  /// Read-before-write: читаем текущий список из state, мержим, пишем целиком —
  /// гасит гонку двух админов на узком окне read→write (спека M5). Возврат =
  /// перезапись списка без юзера (state event удалить нельзя). No-op, если
  /// состояние уже требуемое.
  ///
  /// Локальный state НЕ трогаем оптимистично: обе витрины подписаны на
  /// `client.onRoomState`, и SDK испускает его при приходе /sync-эха этого же
  /// события. Оптимистичный `room.setState` дал бы ДВОЙНУЮ перестройку списка
  /// (сам setState → onRoomState → setFilter, затем /sync-эхо → снова) — лишний
  /// rebuild и дёрганье прокрутки у скрывающего. Задержка обновления на один
  /// sync-цикл (~сотни мс) для косметического админ-действия приемлема.
  Future<void> setMemberHidden(String userId, {required bool hidden}) async {
    final current = hiddenMemberIds;
    final next = nextHiddenMemberIds(current, userId, hidden: hidden);
    if (next.length == current.length && next.containsAll(current)) return;
    await client.setRoomStateWithKey(
      id,
      hiddenMembersState,
      '',
      <String, Object?>{'user_ids': next.toList()},
    );
  }

  /// Разрешено ли ТЕКУЩЕМУ пользователю ставить реакции в этой комнате.
  /// Считает порог именно для `m.reaction`, а не для обычного сообщения.
  bool get canSendReaction => canReactAt(
    ownPowerLevel: ownPowerLevel,
    reactionThreshold:
        getState(EventTypes.RoomPowerLevels)?.content
            .tryGetMap<String, Object?>('events')
            ?.tryGet<int>('m.reaction') ??
        getState(
          EventTypes.RoomPowerLevels,
        )?.content.tryGet<int>('events_default') ??
        0,
  );

  /// Разрешено ли ТЕКУЩЕМУ пользователю снять СВОЮ реакцию в этой комнате.
  ///
  /// Парный к [canSendReaction]: снятие реакции — отдельное событие
  /// `m.room.redaction` со своим порогом. На каналах, созданных до фикса
  /// 2026-08-01 (и не догнанных бэкфиллом
  /// `deploy/scripts/backfill_channel_reaction_powerlevel.py`), порог
  /// `m.room.redaction` в `events` отсутствует и наследует
  /// `events_default: 100` — сервер отвечает `M_FORBIDDEN`. Гейт нужен, чтобы
  /// на таких каналах реакция не выглядела снимаемой и пользователь не ловил
  /// диалог «Нет прав доступа».
  bool get canRedactOwnReaction => canRedactOwnAt(
    ownPowerLevel: ownPowerLevel,
    redactionThreshold:
        getState(EventTypes.RoomPowerLevels)?.content
            .tryGetMap<String, Object?>('events')
            ?.tryGet<int>(EventTypes.Redaction) ??
        getState(
          EventTypes.RoomPowerLevels,
        )?.content.tryGet<int>('events_default') ??
        0,
  );

  /// Реально ли непрочитана комната с точки зрения бейджа иконки.
  ///
  /// Расширяет SDK-геттер `isUnread` (`notificationCount > 0 || markedUnread`)
  /// receipt-based фильтрацией: Synapse может не обнулить
  /// `event_push_summary.notif_count` после прочтения (диагностика 2026-08-31 —
  /// механизм NULL-`event_stream_ordering` для receipt на федеративное событие,
  /// не попавшее в локальную `events`: `_handle_new_receipts_for_notifs_txn`
  /// пропускает такой receipt → summary не сбрасывается). Клиент получает
  /// застрявшее число в `/sync notification_count` и раздул бы по нему бейдж.
  ///
  /// КОНСЕРВАТИВНЫЙ гейт (fail-safe против недосчёта): комнату из бейджа
  /// исключаем ТОЛЬКО при ПОЗИТИВНОМ доказательстве прочтения — есть
  /// preview-`lastEvent` И моя квитанция его покрывает (`hasUnseenMessages ==
  /// false` — ПОРЯДКОВОЕ сравнение из `unseen_messages.dart`: SDK-`hasNewMessages`
  /// сравнивает время квитанции и при частичной квитанции «прочитано = увидено»
  /// врал бы `false`). Если `lastEvent` не загружен / не preview-тип — оценить receipt
  /// нельзя, ДОВЕРЯЕМ серверному счётчику (считаем). Так реальные непрочитанные
  /// (в т.ч. федеративные сообщения ПОСЛЕ receipt) остаются в бейдже, а
  /// вычищается лишь доказанно-прочитанный застрявший notif.
  ///
  /// Инварианты (сохранены):
  /// - invite → всегда в бейдж (нет квитанции без принятия);
  /// - markedUnread → всегда в бейдж (ручная пометка, не про notif_count);
  /// - pushRuleState == dontNotify → НЕ в бейдж (полный мьют; см. ниже — мьют
  ///   НЕ обнуляет notificationCount сам, вопреки прежнему допущению);
  /// - pushRuleState == mentionsOnly (то, что ставит кнопка мьюта в UI) →
  ///   в бейдж ТОЛЬКО при highlightCount > 0, т.е. по реальным упоминаниям;
  /// - notificationCount == 0 и не markedUnread → не в бейдж (fully-read);
  /// - notificationCount > 0, lastEvent не оцениваем → в бейдж (доверие серверу);
  /// - notificationCount > 0, квитанция НЕ покрыла lastEvent → в бейдж (реальный);
  /// - notificationCount > 0, квитанция ПОКРЫЛА preview-lastEvent → НЕ в бейдж.
  bool get _isUnreadForBadge {
    if (membership == Membership.invite) return true;
    if (markedUnread) return true;
    // Полностью замьюченная комната в бейдж не идёт НИКОГДА, даже с
    // notificationCount > 0. Комментарий ниже обещал, что мьют сам приводит
    // счётчик к нулю, — прод это опровергает: мьют prospective-only (новые
    // события не получают `notify`), а СТАРЫЕ строки `event_push_summary`
    // чистит только ресипт, который клиент шлёт лишь при ОТКРЫТИИ комнаты.
    // Замьюченную комнату пользователь не открывает — значит число на иконке
    // он не может обнулить в принципе. Замер 2026-09-09: у одного юзера 8 из
    // 16 notif-комнат замьючены, по флоту таких пользователей 26.
    if (pushRuleState == PushRuleState.dontNotify) return false;
    // `mentionsOnly` — ЭТО ТО, ЧТО СТАВИТ КНОПКА «Отключить уведомления» в Лизе
    // (`chat_settings_popup_menu.dart` → `setPushRuleState(mentionsOnly)`), и
    // потому это ОСНОВНАЯ форма мьюта, а не редкая: прод 2026-09-09 — 665 правил
    // у 88 юзеров против 367 у 29 для `dontNotify`.
    //
    // Здесь нельзя ни считать всё (тогда остаётся неснимаемое число из остатков,
    // накопленных ДО мьюта), ни исключить всё (спрячем реальные упоминания, ради
    // которых режим и выбран). Поэтому считаем РОВНО упоминания: `highlightCount`
    // приходит из `/sync` и обнуляется ресиптом вместе с summary, а обычные
    // непрочитанные в замьюченной комнате в бейдж не идут.
    //
    // ⚠ Первая редакция фикса (2026-09-09) исключала только `dontNotify` и
    // обосновывала это тем, что «в mentionsOnly счётчик растёт от реальных
    // упоминаний». Для НОВЫХ упоминаний верно, для СТАРЫХ остатков — нет, и
    // потому фикс покрывал меньшинство флота.
    if (pushRuleState == PushRuleState.mentionsOnly) return highlightCount > 0;
    if (notificationCount == 0) return false;
    // notificationCount > 0: исключаем только при доказанном прочтении.
    final last = lastEvent;
    final canEvaluateReceipt =
        last != null && client.roomPreviewLastEvents.contains(last.type);
    if (!canEvaluateReceipt) return true; // оценить нельзя → доверяем серверу
    // false ⟺ квитанция покрыла lastEvent → застрявший серверный счётчик.
    // Там же гейт адресного поста Liza News (хвост не для этого устройства →
    // false): news_audience.dart, страж RL-liza-news-platform-audience/12.
    // Частичная квитанция (сепаратор в середине) даёт true — комната честно
    // остаётся в бейдже.
    return hasUnseenMessages;
  }

  /// Идёт ли комната в счётчик бейджа приложения на иконке. Учитываем только
  /// видимые в списке чатов комнаты: скрытые (stories/topology-hidden)
  /// пользователь не может открыть и «прочитать», поэтому их
  /// notificationCount/приглашение не должны оставлять неснимаемую «1».
  /// Персонально раскрытая (isRevealedByMe) комната перестаёт быть скрытой и
  /// снова идёт в бейдж — это корректно, она уже в списке чатов.
  ///
  /// Receipt-based гейт (_isUnreadForBadge) не даёт застрявшему серверному
  /// notif_count раздувать бейдж, если квитанция уже покрыла lastEvent.
  bool get countsTowardAppBadge => !isHiddenChat && _isUnreadForBadge;
}
