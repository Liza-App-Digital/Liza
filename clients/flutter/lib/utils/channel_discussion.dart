import 'package:matrix/matrix.dart';

import 'package:liza/utils/wait_for_room_in_sync.dart';

const channelDiscussionState = 'com.liza.channel.discussion';
const channelParentState = 'com.liza.channel.parent';
const channelPostRefKey = 'com.liza.channel.post_ref';

/// Ключ в content [channelDiscussionState], которым клиент помечает удаление
/// КАНАЛА (а не выключение комментариев). Зеркало серверной
/// `channel_sync._logic.CHANNEL_DELETED_KEY`.
const channelDeletedKey = 'deleted';

extension ChannelDiscussion on Room {
  /// room_id привязанного чата-обсуждения, или null (комментарии выключены).
  ///
  /// `deleted: true` — маркер удаления КАНАЛА, который пишет
  /// [ChatDetailsController.deleteChannelAction] рядом с `room_id` (сервер
  /// иначе не отличает удаление от выключения комментариев, см.
  /// `channel_sync._logic.channel_deleted_of`). Для UI такой канал
  /// комментариев не имеет: он уже удаляется, и открывать по нему ленту
  /// обсуждения нечему. `room_id` в маркере оставлен ради СЕРВЕРА — по нему
  /// фоновые кики находят чат обсуждения независимо от порядка событий.
  String? get discussionRoomId {
    final content = getState(channelDiscussionState)?.content;
    if (content?[channelDeletedKey] == true) return null;
    final id = content?['room_id'];
    return id is String ? id : null;
  }

  bool get hasComments => discussionRoomId != null;

  /// Привязанный чат в том виде, в каком он уже известен клиенту, без сетевых
  /// запросов. Для читателя-не-члена вернёт null — чтение ленты комментариев
  /// строится вокруг этого: подписчик открытого канала в чат не приглашается.
  Room? get discussionRoom {
    final id = discussionRoomId;
    return id == null ? null : client.getRoomById(id);
  }

  /// Комната обсуждения, готовая к чтению/отправке комментариев.
  ///
  /// Подписчик открытого канала в чат не приглашается (там `join_rule:
  /// public`) — членство возникает тихо, при первом обращении. Matrix не
  /// позволяет отправить событие без `join`, поэтому «комментировать не
  /// вступая» имитируется незаметным join; чат при этом скрыт из списка
  /// чатов и замьючен, так что для пользователя вступления не происходит.
  ///
  /// Вызывать только по явному действию пользователя (тап по плашке,
  /// отправка комментария): простой показ ленты вступать в чат не должен.
  Future<Room?> ensureDiscussionMembership() async =>
      (await ensureDiscussionMembershipResult()).room;

  /// То же, что [ensureDiscussionMembership], но с РАЗЛИЧИМОЙ причиной отказа.
  ///
  /// Раньше все четыре исхода схлопывались в `null` и один невнятный snackbar
  /// «Не удалось открыть обсуждение», а `MatrixException` проглатывался в
  /// `Logs().w` — из-за этого баг «тап по плашке ничего не открывает» месяцами
  /// не диагностировался. Теперь вызывающий обязан различать хотя бы
  /// [DiscussionJoinOutcome.rejected] («сервер отказал» — повтор не поможет) и
  /// [DiscussionJoinOutcome.timedOut] («join прошёл, комната не приехала в
  /// sync» — надо предложить повторить).
  Future<DiscussionJoinResult> ensureDiscussionMembershipResult() async {
    final id = discussionRoomId;
    if (id == null) {
      return const DiscussionJoinResult(DiscussionJoinOutcome.noDiscussion);
    }
    final existing = client.getRoomById(id);
    if (existing != null && existing.membership == Membership.join) {
      return DiscussionJoinResult(DiscussionJoinOutcome.joined, room: existing);
    }
    try {
      await client.joinRoom(id, serverName: discussionViaServers(id, this.id));
    } on MatrixException catch (e, s) {
      // errcode в лог обязателен — без него причину отказа с прода не
      // восстановить; пользователю сырой errcode не показываем.
      Logs().w(
        'ensureDiscussionMembership: сервер отверг join $id '
        '(${e.errcode}: ${e.errorMessage})',
        e,
        s,
      );
      return DiscussionJoinResult(
        DiscussionJoinOutcome.rejected,
        room: existing,
        errcode: e.errcode,
      );
    } catch (e, s) {
      Logs().w('ensureDiscussionMembership: join $id не удался', e, s);
      return DiscussionJoinResult(
        DiscussionJoinOutcome.rejected,
        room: existing,
      );
    }
    // Ждём именно появления в sync: joinRoom отвечает раньше, чем комната
    // окажется в client.rooms, и переход в неё упёрся бы в room == null.
    final arrived = await waitForRoomInSync(
      client,
      id,
      timeout: discussionJoinSyncTimeout(
        discussionRoomId: id,
        userId: client.userID,
      ),
    );
    final room = client.getRoomById(id);
    if (!arrived || room == null || room.membership != Membership.join) {
      // Тут join на сервере, скорее всего, УЖЕ прошёл — просто комната не
      // успела приехать в /sync. Говорить «нет доступа» было бы враньём.
      Logs().w(
        'ensureDiscussionMembership: join $id принят, но комната не приехала '
        'в sync за отведённое время (membership=${room?.membership})',
      );
      return DiscussionJoinResult(DiscussionJoinOutcome.timedOut, room: room);
    }
    return DiscussionJoinResult(DiscussionJoinOutcome.joined, room: room);
  }
}

/// Чем закончилась попытка обеспечить членство в чате обсуждения.
enum DiscussionJoinOutcome {
  /// Членство есть — можно открывать тред/отправлять комментарий.
  joined,

  /// У канала нет привязанного чата (комментарии выключены/канал удаляется).
  noDiscussion,

  /// Сервер отказал в join (`M_FORBIDDEN` и прочее). Повтор не поможет.
  rejected,

  /// join сервером принят, но комната не приехала в `/sync` за отведённое
  /// время. Это НЕ «нет доступа» — пользователю предлагаем повторить.
  timedOut,
}

class DiscussionJoinResult {
  const DiscussionJoinResult(this.outcome, {this.room, this.errcode});

  final DiscussionJoinOutcome outcome;

  /// Комната, как её видит клиент на момент выхода: при [timedOut] может быть
  /// null (ещё не приехала) либо с membership != join.
  final Room? room;

  /// errcode отказа сервера — только для лога/диагностики, не для показа.
  final String? errcode;

  bool get isJoined =>
      outcome == DiscussionJoinOutcome.joined &&
      room?.membership == Membership.join;
}

/// Сколько ждать появления чата обсуждения в `/sync` после join.
///
/// Федеративный join (`make_join`/`send_join` к чужому хоумсерверу + прилёт
/// комнаты в `/sync`) в 5 с укладывается НЕ всегда: чат обсуждения живёт на
/// сервере канала, а подписчик приходит со своего. На проде это давало
/// «Не удалось открыть обсуждение» при УСПЕШНОМ join
/// (`!mfdTYXVAQpplDCNTJA:nadezhda.liza.ru`, подписчики с
/// `synapse.liza.laba.prodamus.tech`).
///
/// 20 с — не «побольше на всякий случай»: `send_join` к чужому HS упирается в
/// федеративный таймаут Synapse (`federation_client` держит запрос до ~20 с,
/// столько же `/sync` может отдавать длинный ответ). Меньший бюджет обрывает
/// ожидание РАНЬШЕ, чем сервер вообще успевает ответить, — то есть гарантирует
/// ложный отказ на медленной федерации; больший — заставляет пользователя
/// смотреть на спиннер дольше, чем сервер физически может отвечать.
///
/// Локальная комната (домен room_id == домен пользователя) остаётся на прежних
/// 5 с: там ждать нечего кроме своего же sync-цикла, и раздувать бюджет значило
/// бы на ровном месте удлинять спиннер при реальном сбое.
Duration discussionJoinSyncTimeout({
  required String discussionRoomId,
  required String? userId,
}) {
  final colon = discussionRoomId.indexOf(':');
  final roomServer = colon < 0 ? null : discussionRoomId.substring(colon + 1);
  final userColon = userId?.indexOf(':') ?? -1;
  final userServer = userColon < 0 ? null : userId!.substring(userColon + 1);
  if (roomServer == null || userServer == null || roomServer == userServer) {
    return const Duration(seconds: 5);
  }
  return const Duration(seconds: 20);
}

/// event_id зеркала поста [postEventId] среди [events] обсуждения, или null,
/// если зеркало ещё не загружено/не создано.
String? findMirrorEventId(
  List<Map<String, dynamic>> events,
  String postEventId,
) {
  for (final e in events) {
    final ref = (e['content'] as Map?)?[channelPostRefKey];
    if (ref is Map && ref['post_event_id'] == postEventId) {
      return e['event_id'] as String?;
    }
  }
  return null;
}

/// event_id, на который отвечает событие [e] через `m.in_reply_to`, или null,
/// если это не reply (либо `content`/`m.relates_to` испорчены/отсутствуют).
///
/// `content` в теории всегда Map (так его отдаёт Matrix SDK), но входные
/// данные тут — сырые JSON-подобные структуры, поэтому используем `is Map`
/// вместо `as Map?`: `as` уронил бы всю функцию (и оба её вызова —
/// `countReplies`/`repliesToMirror`) на событии с `content` не-Map-типа,
/// а `is` просто трактует такое событие как «не reply».
String? _inReplyToEventId(Map<String, dynamic> e) {
  final content = e['content'];
  if (content is! Map) return null;
  final rel = content['m.relates_to'];
  if (rel is! Map) return null;
  final reply = rel['m.in_reply_to'];
  if (reply is! Map) return null;
  final id = reply['event_id'];
  return id is String ? id : null;
}

/// Число ПРЯМЫХ reply на зеркало поста в загруженном таймлайне обсуждения.
///
/// Для плашки «N комментариев» под постом НЕ подходит — она обязана считать
/// то же, что показывает тред, то есть [countThreadComments]. Оставлена как
/// строительный блок [countThreadComments] и точка проверки самого отбора.
int countReplies(List<Map<String, dynamic>> events, String postEventId) {
  final mirrorId = findMirrorEventId(events, postEventId);
  if (mirrorId == null) return 0;
  return repliesToMirror(events, mirrorId).length;
}

/// Число комментариев в треде поста — ровно то, что покажет экран треда.
///
/// Считает [threadEvents] (прямые ответы на зеркало ПЛЮС ответы на них), а не
/// [countReplies] (только прямые). Иначе плашка и тред расходятся: пост с
/// одним комментарием и пятью ответами на него показывал бы «1 комментарий»,
/// а внутри лежало бы шесть. Так же ведёт себя Liza — счётчик под постом
/// показывает ВСЕ комментарии обсуждения, а не только корневые.
int countThreadComments(List<Map<String, dynamic>> events, String postEventId) {
  final mirrorId = findMirrorEventId(events, postEventId);
  if (mirrorId == null) return 0;
  return threadEvents(events, mirrorId).length;
}

/// Комментарии к зеркалу поста — в порядке появления во входном списке.
///
/// Тред плоский: ответ на ответ не вкладывается, а показывается цитатой,
/// как в Liza.
List<Map<String, dynamic>> repliesToMirror(
  List<Map<String, dynamic>> events,
  String mirrorId,
) {
  return [
    for (final e in events)
      if (_inReplyToEventId(e) == mirrorId) e,
  ];
}

/// Все события треда: прямые ответы на зеркало плюс ответы на эти ответы.
///
/// [repliesToMirror] отбирает только ПРЯМЫЕ ответы на зеркало, а ответ на
/// комментарий указывает `m.in_reply_to` уже на сам комментарий — без этой
/// функции он пропал бы из треда. Вложенность не вводим: второй уровень
/// показывается в общем плоском списке с цитатой-заголовком, как в Liza.
/// Глубже второго уровня не идём — цепочку «ответ на ответ на ответ» Liza
/// тоже держит плоской, привязывая её к корню обсуждения.
///
/// Порядок входного списка сохраняется.
List<Map<String, dynamic>> threadEvents(
  List<Map<String, dynamic>> events,
  String mirrorId,
) {
  final direct = repliesToMirror(events, mirrorId);
  final directIds = {for (final e in direct) e['event_id']};
  return [
    for (final e in events)
      if (_inReplyToEventId(e) == mirrorId ||
          directIds.contains(_inReplyToEventId(e)))
        e,
  ];
}

/// event_id, на который ОБЯЗАН ссылаться новый ответ из треда, чтобы остаться
/// в плоском 2-уровневом треде.
///
/// Тред плоский и двухуровневый ([threadEvents]): прямые ответы на зеркало
/// (ур.1) + ответы на них (ур.2). Ответ 3-го уровня выпал бы из [threadEvents]
/// и [countThreadComments] — «отправил, но пропало». Поэтому адресата
/// СХЛОПЫВАЕМ:
/// - ответ на прямой комментарий (ур.1) → ссылаемся на него же (станет ур.2);
/// - ответ на ответ (ур.2) → ссылаемся на его РОДИТЕЛЯ (ур.1), чтобы новый
///   ответ остался ур.2 (адресата-автора сохраняем @упоминанием в тексте);
/// - ответ прямо на пост → на зеркало.
/// Чистая функция — тестируется без Room.
String threadReplyAnchorId(Map<String, dynamic> target, String mirrorId) {
  final targetId = target['event_id'];
  final parent = _inReplyToEventId(target);
  // Цель без in_reply_to (не часть треда) → защитно на зеркало, чтобы ответ
  // гарантированно остался в треде.
  if (parent == null) return mirrorId;
  // Цель — прямой комментарий (ур.1): отвечаем на него же → ответ станет ур.2.
  if (parent == mirrorId) return targetId is String ? targetId : mirrorId;
  // Цель — ответ на комментарий (ур.2): схлопываем на родителя ур.1.
  return parent;
}

/// Событие треда, на которое отвечает [event], — для цитаты-заголовка.
/// null, если это ответ прямо на пост (зеркало) либо адресат не загружен.
Map<String, dynamic>? quotedComment(
  List<Map<String, dynamic>> events,
  Map<String, dynamic> event,
  String mirrorId,
) {
  final target = _inReplyToEventId(event);
  if (target == null || target == mirrorId) return null;
  for (final candidate in events) {
    if (candidate['event_id'] == target) return candidate;
  }
  return null;
}

/// Нужна ли ещё порция истории обсуждения, чтобы найти зеркало поста.
///
/// Окно загрузки — это окно ВСЕГО чата, а не треда: в активном обсуждении
/// зеркало старого поста в первую порцию не попадает. Потолок [maxBatches]
/// обязателен — иначе на «болтливом» чате подгрузка не закончится.
bool needsMoreHistory({
  required List<Map<String, dynamic>> events,
  required String postEventId,
  required int loadedBatches,
  required int maxBatches,
}) {
  if (loadedBatches >= maxBatches) return false;
  return findMirrorEventId(events, postEventId) == null;
}

/// Открытый ли канал по его join_rule. Зеркало серверной
/// `channel_sync._logic.is_public_channel`.
bool isChannelPublic(String? joinRule) => joinRule == 'public';

/// Настройки привязанного чата под приватность канала. Зеркало серверной
/// `channel_sync._logic.discussion_settings_for` — клиент выставляет их при
/// создании чата, сервер поддерживает при смене приватности канала.
///
/// Закрытый канал → `restricted` по членству в КАНАЛЕ: доступ к обсуждению
/// даёт сама подписка, без приглашений (механика Telegram, Надежда 15.10).
/// Неизвестное правило трактуем как закрытый канал: ошибка в сторону
/// приватности не раскрывает чужие комментарии.
Map<String, dynamic> discussionSettingsFor(
  String? channelJoinRule,
  String channelId,
) {
  if (isChannelPublic(channelJoinRule)) {
    return {'join_rule': 'public', 'history_visibility': 'world_readable'};
  }
  return {
    'join_rule': 'restricted',
    'allow': [
      {'type': 'm.room_membership', 'room_id': channelId},
    ],
    'history_visibility': 'shared',
  };
}

/// content `m.room.join_rules` из [discussionSettingsFor]: `restricted` без
/// `allow` не пустил бы никого, поэтому `allow` едет вместе с правилом.
Map<String, dynamic> discussionJoinRulesContent(
  Map<String, dynamic> settings,
) => {
  'join_rule': settings['join_rule'],
  if (settings.containsKey('allow')) 'allow': settings['allow'],
};

/// Серверы, у которых можно спросить о чате-обсуждении при join.
///
/// Домен выводим из room_id (часть после ПЕРВОГО двоеточия — в имени сервера
/// может быть порт), а не читаем из room-state: `com.liza.channel.discussion`
/// хранит только `room_id`, и у всех уже созданных каналов `via` там нет.
///
/// Зачем вообще: подписчик может сидеть в канале ЧУЖОГО сервера по федерации,
/// а чат-обсуждения живёт там же. Свой сервер о такой комнате не знает ничего
/// (проверено на проде: `/state` отдаёт 0 событий), и join по голому room_id
/// принципиально невозможен — некого спросить о комнате.
List<String> discussionViaServers(
  String discussionRoomId,
  String channelRoomId,
) {
  final servers = <String>[];
  for (final id in [discussionRoomId, channelRoomId]) {
    final colon = id.indexOf(':');
    if (colon < 0 || colon + 1 >= id.length) continue;
    final server = id.substring(colon + 1);
    if (!servers.contains(server)) servers.add(server);
  }
  return servers;
}
