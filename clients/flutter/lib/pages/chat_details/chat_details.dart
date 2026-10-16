import 'package:flutter/material.dart';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_details/chat_details_view.dart';
import 'package:liza/pages/settings/settings.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/channel_discussion.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/file_selector.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/room_name_limit.dart';
import 'package:liza/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';

enum AliasActions { copy, delete, setCanonical }

/// Диалог переименования чата/группы/канала/компании. Вынесен из
/// [ChatDetailsController], чтобы страж реестра рендерил РЕАЛЬНЫЙ диалог, а не
/// его реплику.
///
/// Без `minLines`/`maxLines` [DialogTextField] отдаёт `TextField(maxLines:
/// null)` — поле разрасталось на тысячи строк и выдавливало кнопки из окна
/// (LABA-2536). Валидатора по `runes` здесь нет намеренно: сервер длину
/// `m.room.name` не проверяет (см. [maxRoomNameLength]), поэтому уже
/// сохранённое длинное имя показывается целиком — его можно укоротить, а не
/// упереться в заблокированный «Ок».
///
/// Пустое имя отбивается (LABA-2534): иначе группа без других участников
/// превращалась в «Пустой чат». Поэтому в поле — настоящее [currentName], а не
/// вычисляемое [computedName]: у безымянной группы «Ок» без правок записывал
/// «Группа с X» буквально, и после запрета пустого имени это стало бы
/// необратимым. Вычисляемое имя — только подсказкой и только у безымянной:
/// у названной рядом с ошибкой оно обещало бы запрещённый откат.
Future<String?> showRoomNameInputDialog(
  BuildContext context, {
  required String currentName,
  required String computedName,
}) async {
  final name = await showTextInputDialog(
    context: context,
    title: L10n.of(context).changeTheNameOfTheGroup,
    okLabel: L10n.of(context).ok,
    cancelLabel: L10n.of(context).cancel,
    initialText: currentName,
    hintText: currentName.isEmpty ? computedName : null,
    minLines: 1,
    maxLines: 1,
    maxLength: maxRoomNameLength,
    validator: (text) =>
        text.trim().isEmpty ? L10n.of(context).pleaseEnterAName : null,
  );
  return name?.trim();
}

/// Имя для `m.room.name` по результату [showRoomNameInputDialog]; `null` —
/// ничего не отправлять (отмена, пусто или имя не изменилось).
String? roomRenameTarget(String? input, {required String currentName}) {
  final name = input?.trim();
  if (name == null || name.isEmpty || name == currentName) return null;
  return name;
}

/// initialState привязанного чата-обсуждения канала.
///
/// Приватность наследуется от канала: открытый канал → чат public +
/// world_readable (комментарии читаются без членства), закрытый → restricted
/// по членству в канале + shared. Чат всегда помечается скрытым: подписчик не должен видеть его в
/// списке чатов отдельной строкой (телеграмная модель).
List<StateEvent> buildDiscussionInitialState({
  required String channelId,
  required String? channelJoinRule,
}) {
  final settings = discussionSettingsFor(channelJoinRule, channelId);
  return [
    StateEvent(type: channelParentState, content: {'room_id': channelId}),
    StateEvent(type: 'com.liza.chat.topology', content: {'hidden': true}),
    StateEvent(
      type: 'm.room.join_rules',
      content: discussionJoinRulesContent(settings),
    ),
    StateEvent(
      type: 'm.room.history_visibility',
      content: {'history_visibility': settings['history_visibility']},
    ),
  ];
}

/// room_id ранее привязанного чата-обсуждения канала [channelId], если он
/// сохранился после выключения комментариев.
///
/// Повторное включение обязано вернуть прежний чат со всей историей —
/// создание новой пустой комнаты выглядело бы для пользователя как потеря
/// всех комментариев.
///
/// ⚠️ Эта функция сама НЕ проверяет маркер удаления канала (`deleted: true`
/// в `channelDiscussionState`, см. `channel_discussion.dart`) — она смотрит
/// только на `com.liza.channel.parent`, который переживает и отвязку, и
/// удаление канала. Значит для удалённого канала функция тоже нашла бы
/// прежний чат — и это НАМЕРЕННО: `deleteChannelAction` документирует
/// случай, когда удаление сорвалось ПОСЛЕ записи маркера, и канал остаётся
/// живым с `{'room_id': X, 'deleted': true}'`; повторное включение
/// комментариев в этом случае обязано восстановить прежний чат, а не
/// плодить новый. Безопасность вызова единственного места
/// (`ChatDetailsController.enableChannelComments`) обеспечивает НЕ эта
/// функция, а guard ВЫШЕ по коду —
/// `if (channel.discussionRoomId != null) return;`, который читает тот же
/// маркер через `Room.discussionRoomId` (трактует `deleted: true` как
/// «комментариев нет» и пропускает дальше). Переставь вызов этой функции
/// выше guard'а или убери guard — и эта функция начнёт молча перезаписывать
/// state уже удаляемого канала. Если понадобится инвариант понадёжнее — его
/// место здесь, а не в вызывающем коде.
/// room_id привязанного чата обсуждения из СЫРОГО content состояния
/// `com.liza.channel.discussion`, прочитанного с сервера.
///
/// Отдельно от `Room.discussionRoomId` (который читает локальный снимок) и
/// намеренно ЧИСТАЯ — чтобы проверять разбор без живого клиента.
///
/// Маркер удаления канала (`deleted: true`) трактуем как «привязки нет»: это
/// тот же контракт, что у `Room.discussionRoomId`, иначе включение
/// комментариев на канале с сорвавшимся удалением молча не сработало бы.
String? boundDiscussionFromState(Map<String, Object?>? content) {
  if (content == null) return null;
  if (content[channelDeletedKey] == true) return null;
  final id = content['room_id'];
  return id is String && id.isNotEmpty ? id : null;
}

String? findDetachedDiscussion(
  List<Map<String, dynamic>> rooms,
  String channelId,
) {
  for (final r in rooms) {
    if (r['chat_type'] == 'channel_discussion' && r['parent'] == channelId) {
      return r['room_id'] as String?;
    }
  }
  return null;
}

/// Домен сервера, на котором ЖИВЁТ комната.
///
/// Ник канала регистрируется в auth-proxy под сервером КАНАЛА. Прежний код
/// брал домен из `client.userID`, то есть домен ПОЛЬЗОВАТЕЛЯ — у подписчика с
/// чужого хоумсервера запрос уходил не на тот сервер, возвращал 404, и QR
/// откатывался на нерабочую matrix.to-ссылку.
String? serverNameForRoom(String roomId) {
  final separator = roomId.indexOf(':');
  if (separator < 0 || separator == roomId.length - 1) return null;
  return roomId.substring(separator + 1);
}

class ChatDetails extends StatefulWidget {
  final String roomId;
  final Widget? embeddedCloseButton;

  /// Режим "Детали" для обычного юзера: скрыть видимость/права/участников
  /// и редактирование (только просмотр имени/аватара/описания/call-link).
  final bool detailsOnly;

  const ChatDetails({
    super.key,
    required this.roomId,
    this.embeddedCloseButton,
    this.detailsOnly = false,
  });

  @override
  ChatDetailsController createState() => ChatDetailsController();
}

class ChatDetailsController extends State<ChatDetails> {
  bool displaySettings = false;

  void toggleDisplaySettings() =>
      setState(() => displaySettings = !displaySettings);

  String? get roomId => widget.roomId;

  /// Ник канала (для ссылки в QR и тайла в деталях). Загружается сетевым
  /// запросом при открытии экрана — отсутствие результата (ошибка сети,
  /// ника нет) не должно ломать экран, поэтому ошибку просто логируем.
  ChannelHandleInfo? channelHandle;

  Future<void> _loadChannelHandle() async {
    final room = Matrix.of(context).client.getRoomById(roomId!);
    if (room == null || !room.isChannel) return;
    final serverName = serverNameForRoom(room.id);
    final accessToken = room.client.accessToken;
    if (serverName == null || accessToken == null) return;
    try {
      final resolved = await AuthProxyService().resolveChannelHandleForRoom(
        serverName: serverName,
        roomId: room.id,
        accessToken: accessToken,
      );
      if (!mounted) return;
      setState(() => channelHandle = resolved);
    } catch (e, s) {
      Logs().w('ChatDetails: не удалось загрузить ник канала $roomId', e, s);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadChannelHandle();
  }

  void setDisplaynameAction() async {
    final room = Matrix.of(context).client.getRoomById(roomId!)!;
    final input = await showRoomNameInputDialog(
      context,
      currentName: room.name,
      computedName: room.getLocalizedDisplayname(
        MatrixLocals(L10n.of(context)),
      ),
    );
    final name = roomRenameTarget(input, currentName: room.name);
    if (name == null || !mounted) return;
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => room.setName(name),
    );
    if (!mounted) return;
    if (success.error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).displaynameHasBeenChanged)),
      );
    }
  }

  static const callLinkEventType = 'io.element.call_link';

  void setCallLinkAction() async {
    final room = Matrix.of(context).client.getRoomById(roomId!)!;
    final currentUrl =
        room.getState(callLinkEventType)?.content['url'] as String? ?? '';
    final input = await showTextInputDialog(
      context: context,
      title: L10n.of(context).setCallLink,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      hintText: 'https://',
      initialText: currentUrl,
    );
    if (input == null) return;
    final trimmed = input.trim();
    if (trimmed.isNotEmpty &&
        !trimmed.startsWith('https://') &&
        !trimmed.startsWith('http://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).callLinkInvalidUrl)),
      );
      return;
    }
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => room.client.setRoomStateWithKey(
        room.id,
        callLinkEventType,
        '',
        trimmed.isEmpty ? {} : {'url': trimmed},
      ),
    );
    if (success.error == null && mounted) {
      room.setState(
        StrippedStateEvent(
          type: callLinkEventType,
          content: trimmed.isEmpty ? {} : {'url': trimmed},
          stateKey: '',
          senderId: room.client.userID!,
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trimmed.isEmpty
                ? L10n.of(context).callLinkDeleted
                : L10n.of(context).callLinkSaved,
          ),
        ),
      );
    }
  }

  void deleteCallLinkAction() async {
    final room = Matrix.of(context).client.getRoomById(roomId!)!;
    final success = await showFutureLoadingDialog(
      context: context,
      future: () =>
          room.client.setRoomStateWithKey(room.id, callLinkEventType, '', {}),
    );
    if (success.error == null && mounted) {
      room.setState(
        StrippedStateEvent(
          type: callLinkEventType,
          content: {},
          stateKey: '',
          senderId: room.client.userID!,
        ),
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L10n.of(context).callLinkDeleted)));
    }
  }

  /// Идёт ли прямо сейчас включение комментариев. Без этого флага ДВА быстрых
  /// тапа проходят guard `discussionRoomId != null` оба: привязка приезжает в
  /// `/sync` уже после того, как второй тап её прочитал, — и канал получает
  /// ДВА чата обсуждения (на проде так и вышло у
  /// `!imFpwmDxzbZyFMaFtN:nadezhda.liza.ru`: `!mfdTYXVAQpplDCNTJA` привязан,
  /// `!GZEsNZjzRENLPCFUXa` осиротел). `showFutureLoadingDialog` от этого не
  /// спасает — он поднимается уже ПОСЛЕ await'а requestParticipants().
  bool _enablingComments = false;

  void enableChannelComments() async {
    if (_enablingComments) return;
    final client = Matrix.of(context).client;
    final channel = client.getRoomById(roomId!)!;
    // Идемпотентность: привязка уже есть — повторное нажатие не должно
    // создавать вторую комнату-обсуждение (см. также п.2 ниже про запись
    // state сразу после createRoom).
    //
    // Этот guard — ЕДИНСТВЕННОЕ место, которое ограничивает область действия
    // findDetachedDiscussion ниже: сама она канал с маркером `deleted: true`
    // не отличает от живого (см. её dartdoc). Убрать guard или переставить
    // findDetachedDiscussion выше него — значит потерять эту защиту.
    if (channel.discussionRoomId != null) return;
    _enablingComments = true;
    try {
      await _enableChannelCommentsInner(client, channel);
    } finally {
      _enablingComments = false;
    }
  }

  /// Привязка чата обсуждения ПО ДАННЫМ СЕРВЕРА, а не локального снимка.
  ///
  /// Ошибку глотаем: если состояние прочитать не удалось (сеть, права), лучше
  /// продолжить создание, чем оставить пользователя без комментариев. Дубль в
  /// этом случае всё ещё возможен, но это худший из двух исходов лишь при
  /// одновременно упавшей сети И параллельной сессии.
  Future<String?> _serverDiscussionRoomId(
    Client client,
    String channelId,
  ) async {
    try {
      final content = await client.getRoomStateWithKey(
        channelId,
        channelDiscussionState,
        '',
      );
      return boundDiscussionFromState(content);
    } on MatrixException catch (e) {
      // M_NOT_FOUND — привязки просто нет, это нормальный путь.
      if (e.errcode == 'M_NOT_FOUND') return null;
      Logs().w('enableChannelComments: не прочитать привязку $channelId', e);
      return null;
    } catch (e, s) {
      Logs().w('enableChannelComments: не прочитать привязку $channelId', e, s);
      return null;
    }
  }

  Future<void> _enableChannelCommentsInner(Client client, Room channel) async {
    final channelName = channel.getLocalizedDisplayname(
      MatrixLocals(L10n.of(context)),
    );
    // getParticipants() отдаёт только локально загруженный (при lazy
    // loading — неполный) список. requestParticipants() догружает полный
    // список членов с сервера (/members), иначе часть админов PL>=99
    // может не попасть в инвайты и не получить зеркало своих постов.
    final participants = await channel.requestParticipants();
    final admins = participants
        .where(
          (u) =>
              channel.getPowerLevelByUserId(u.id) >= adminPowerLevel &&
              u.id != client.userID,
        )
        .map((u) => u.id)
        .toList();
    // Отвязка (выключение комментариев) чат НЕ удаляет — только очищает
    // привязку (Task 12, channel_sync). Прежде чем создавать новую комнату,
    // ищем среди уже известных клиенту чат обсуждения ЭТОГО канала: как в
    // Телеграме, повторное включение обязано вернуть старую историю, а не
    // завести пустую комнату-дубль.
    // Сначала фильтруем по дешёвому state-событию parent (нужной комнаты,
    // как правило, единицы среди client.rooms) и только для отобранных
    // читаем m.room.create через lizaChatType — иначе оно вычислялось бы
    // для КАЖДОЙ комнаты клиента, хотя дальше нужны только обсуждения.
    final knownRooms = [
      for (final r in client.rooms)
        if (r.getState(channelParentState)?.content['room_id'] == channel.id)
          {'room_id': r.id, 'chat_type': r.lizaChatType, 'parent': channel.id},
    ];
    final existingDiscussionId = findDetachedDiscussion(knownRooms, channel.id);
    final success = await showFutureLoadingDialog(
      context: context,
      future: () async {
        if (existingDiscussionId != null) {
          // Прежний чат нашёлся локально — просто восстанавливаем привязку,
          // без создания новой комнаты и без повторных инвайтов (участники
          // уже состоят в чате с прошлого раза).
          await client.setRoomStateWithKey(
            channel.id,
            channelDiscussionState,
            '',
            {'room_id': existingDiscussionId},
          );
          return existingDiscussionId;
        }
        // Последний рубеж перед созданием комнаты: перечитываем привязку С
        // СЕРВЕРА. Guard выше и findDetachedDiscussion читают ЛОКАЛЬНЫЙ снимок
        // (`Room.getState` / `client.rooms`), а он отстаёт и бывает неполон:
        // привязку мог записать ДРУГОЙ клиент/устройство того же пользователя,
        // а прежний чат обсуждения мог не приехать в этот sync вовсе (или быть
        // забыт). Именно так на проде у одного канала оказалось ДВА чата
        // обсуждения с РАЗНЫМИ шаблонами имени — то есть созданных разными
        // сессиями/версиями клиента. Сетевой запрос тут дешёвый: он делается
        // ровно один раз за включение комментариев.
        final serverBound = await _serverDiscussionRoomId(client, channel.id);
        if (serverBound != null) return serverBound;
        final discussionId = await client.createRoom(
          preset: CreateRoomPreset.privateChat,
          creationContent: {'com.liza.chat.type': channelDiscussionChatType},
          name: L10n.of(context).channelDiscussionRoomName(channelName),
          // joinRules.text, а не .name: wire-значение join_rule лежит в .text
          // (у knockRestricted .name дал бы 'knockRestricted').
          initialState: buildDiscussionInitialState(
            channelId: channel.id,
            channelJoinRule: channel.joinRules?.text,
          ),
        );
        // Привязку пишем СРАЗУ после создания комнаты, до инвайтов.
        // Если инвайт админа упадёт (бан/сеть), hasComments всё равно
        // станет true и повторное нажатие не создаст комнату-сироту —
        // вместо этого сработает guard выше.
        await client.setRoomStateWithKey(
          channel.id,
          channelDiscussionState,
          '',
          {'room_id': discussionId},
        );
        // Инвайты — best-effort per-admin: падение одного (уже
        // приглашён/забанен/сетевая ошибка) не должно срывать всю
        // операцию. Не полагаемся на client.getRoomById(discussionId)
        // сразу после createRoom: комната появляется в client.rooms
        // только через /sync. inviteUser не требует локального объекта
        // Room, вызываем напрямую.
        for (final adminId in admins) {
          try {
            await client.inviteUser(discussionId, adminId);
          } catch (e, s) {
            Logs().w(
              'enableChannelComments: не удалось пригласить $adminId в $discussionId',
              e,
              s,
            );
          }
        }
        return discussionId;
      },
    );
    if (success.error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).channelCommentsEnabled)),
      );
    }
  }

  void disableChannelComments() async {
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: L10n.of(context).disableChannelCommentsConfirmTitle,
      message: L10n.of(context).disableChannelCommentsConfirmText,
      okLabel: L10n.of(context).disableChannelComments,
      cancelLabel: L10n.of(context).cancel,
      isDestructive: true,
    );
    if (confirmed != OkCancelResult.ok) return;

    final client = Matrix.of(context).client;
    final channel = client.getRoomById(roomId!)!;
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => client.setRoomStateWithKey(
        channel.id,
        channelDiscussionState,
        '',
        {},
      ),
    );
    if (success.error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).channelCommentsDisabled)),
      );
    }
  }

  /// Переход в привязанный чат: снимает скрытость и мьют — подписчик
  /// осознанно вступает в обсуждение (режим 3 модели комментариев).
  void openDiscussionAction() async {
    final channel = Matrix.of(context).client.getRoomById(roomId!)!;
    final router = GoRouter.of(context);
    final result = await showFutureLoadingDialog(
      context: context,
      future: () async {
        final joinResult = await channel.ensureDiscussionMembershipResult();
        final discussion = joinResult.room;
        if (!joinResult.isJoined || discussion == null) return joinResult;
        // Раскрытие и размьют — второстепенные операции: их отказ (сеть,
        // права) не должен лишать пользователя перехода в обсуждение, ради
        // которого он нажал кнопку. Поэтому каждая в своём try.
        try {
          await discussion.revealChatForMe();
        } catch (e, s) {
          Logs().w('openDiscussionAction: раскрытие ${discussion.id}', e, s);
        }
        try {
          await discussion.setPushRuleState(PushRuleState.notify);
        } catch (e, s) {
          Logs().w('openDiscussionAction: размьют ${discussion.id}', e, s);
        }
        return joinResult;
      },
    );
    final joinResult = result.result;
    if (joinResult == null || !joinResult.isJoined) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Таймаут sync — не отказ в доступе: предлагаем повторить.
            joinResult?.outcome == DiscussionJoinOutcome.timedOut
                ? L10n.of(context).channelDiscussionOpenSlow
                : L10n.of(context).channelDiscussionOpenFailed,
          ),
        ),
      );
      return;
    }
    router.go('/rooms/${joinResult.room!.id}');
  }

  /// Удаление канала владельцем: кикает подписчиков, затем сам покидает и
  /// забывает канал и привязанный чат. Полного «стереть у всех» в Matrix нет —
  /// комнаты остаются на сервере, но исчезают у пользователей.
  ///
  /// Маркер удаления (`deleted: true`) необратим и нигде не отображается: если
  /// удаление сорвётся уже после его записи (упал `leave`), канал останется
  /// живым, но с виду без комментариев — ни один экран это состояние не
  /// показывает. Чинится повторным включением комментариев (перезапишет
  /// привязку) либо повторным удалением.
  void deleteChannelAction() async {
    final client = Matrix.of(context).client;
    final channel = client.getRoomById(roomId!)!;
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: L10n.of(context).deleteChannel,
      message: L10n.of(context).deleteChannelConfirm,
      okLabel: L10n.of(context).delete,
      cancelLabel: L10n.of(context).cancel,
      isDestructive: true,
    );
    if (confirmed != OkCancelResult.ok) return;

    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final deleteLabel = L10n.of(context).channelDeleted;
    final success = await showFutureLoadingDialog(
      context: context,
      future: () async {
        final discussionId = channel.discussionRoomId;
        final participants = await channel.requestParticipants();
        // Кик per-участник в своём try: отказ по одному (уже вышел, PL выше,
        // сетевая ошибка) не должен срывать удаление канала целиком.
        for (final user in participants) {
          if (user.id == client.userID) continue;
          try {
            await channel.kick(user.id);
          } catch (e, s) {
            Logs().w(
              'deleteChannelAction: не удалось кикнуть ${user.id}',
              e,
              s,
            );
          }
        }
        if (discussionId != null) {
          // Маркер удаления КАНАЛА для channel_sync. В Matrix нет события
          // «комната удалена» (удаление — это кик+leave+forget), а простую
          // отвязку сервер обязан переживать без потерь: выключение
          // комментариев связь постов с комментариями сохраняет, чтобы
          // повторное включение вернуло старые треды (как в Liza).
          // Отличить удаление от отвязки сервер может только по этому явному
          // флагу, и написать его надо ДО leave — после выхода прав на
          // state канала уже нет.
          //
          // room_id пишем РЯДОМ с флагом, а не затираем: кики выше сервер
          // обрабатывает фоново (run_as_background_process), и часть этих
          // процессов дочитает привязку уже после маркера. Голый
          // {'deleted': true} означал бы для них «комментариев нет» → часть
          // подписчиков осталась бы членами чата обсуждения. С room_id
          // порядок записи перестаёт что-либо решать (для UI такой канал
          // всё равно без комментариев — см. `discussionRoomId`).
          try {
            await client.setRoomStateWithKey(
              channel.id,
              channelDiscussionState,
              '',
              {'room_id': discussionId, channelDeletedKey: true},
            );
          } catch (e, s) {
            Logs().w(
              'deleteChannelAction: маркер удаления ${channel.id}',
              e,
              s,
            );
          }
          try {
            await client.leaveRoom(discussionId);
            await client.forgetRoom(discussionId);
          } catch (e, s) {
            Logs().w('deleteChannelAction: чат $discussionId', e, s);
          }
        }
        await channel.leave();
        await channel.forget();
      },
    );
    if (success.error == null) {
      messenger.showSnackBar(SnackBar(content: Text(deleteLabel)));
      router.go('/rooms');
    }
  }

  void setTopicAction() async {
    final room = Matrix.of(context).client.getRoomById(roomId!)!;
    final input = await showTextInputDialog(
      context: context,
      title: room.isChannel
          ? L10n.of(context).setChannelDescription
          : L10n.of(context).setChatDescription,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      hintText: room.isChannel
          ? L10n.of(context).noChannelDescriptionYet
          : L10n.of(context).noChatDescriptionYet,
      initialText: room.topic,
      minLines: 4,
      maxLines: 8,
    );
    if (input == null) return;
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => room.setDescription(input),
    );
    if (success.error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            room.isChannel
                ? L10n.of(context).channelDescriptionHasBeenChanged
                : L10n.of(context).chatDescriptionHasBeenChanged,
          ),
        ),
      );
    }
  }

  void setAvatarAction() async {
    final room = Matrix.of(context).client.getRoomById(roomId!);
    final actions = [
      if (PlatformInfos.isMobile)
        AdaptiveModalAction(
          value: AvatarAction.camera,
          label: L10n.of(context).openCamera,
          isDefaultAction: true,
          icon: const Icon(Icons.camera_alt_outlined),
        ),
      AdaptiveModalAction(
        value: AvatarAction.file,
        label: L10n.of(context).openGallery,
        icon: const Icon(Icons.photo_outlined),
      ),
      if (room?.avatar != null)
        AdaptiveModalAction(
          value: AvatarAction.remove,
          label: L10n.of(context).delete,
          isDestructive: true,
          icon: const Icon(Icons.delete_outlined),
        ),
    ];
    final action = actions.length == 1
        ? actions.single.value
        : await showModalActionPopup<AvatarAction>(
            context: context,
            title: L10n.of(context).editRoomAvatar,
            cancelLabel: L10n.of(context).cancel,
            actions: actions,
          );
    if (action == null) return;
    if (action == AvatarAction.remove) {
      await showFutureLoadingDialog(
        context: context,
        future: () => room!.setAvatar(null),
      );
      return;
    }
    MatrixFile file;
    if (PlatformInfos.isMobile) {
      final result = await ImagePicker().pickImage(
        source: action == AvatarAction.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        imageQuality: 50,
      );
      if (result == null) return;
      file = MatrixFile(bytes: await result.readAsBytes(), name: result.path);
    } else {
      final picked = await selectFiles(
        context,
        allowMultiple: false,
        type: FileType.image,
      );
      final pickedFile = picked.firstOrNull;
      if (pickedFile == null) return;
      file = MatrixFile(
        bytes: await pickedFile.readAsBytes(),
        name: pickedFile.name,
      );
    }
    await showFutureLoadingDialog(
      context: context,
      future: () => room!.setAvatar(file),
    );
  }

  static const fixedWidth = 360.0;

  @override
  Widget build(BuildContext context) => ChatDetailsView(this);
}
