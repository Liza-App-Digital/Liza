import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:collection/collection.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_shortcuts_new/flutter_shortcuts_new.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/utils/app_badge.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/client_download_content_extension.dart';
import 'package:liza/utils/client_manager.dart';
import 'package:liza/utils/forced_list_artifact.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/news_audience.dart';
import 'package:liza/utils/notification_background_handler.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/push_client_resolver.dart';
import 'package:liza/utils/read_marker_logic.dart';
import 'package:liza/utils/screen_lock_state.dart';
import 'package:liza/utils/strip_matrix_mentions.dart';
import 'package:liza/utils/update_policy.dart';

const notificationAvatarDimension = 128;

/// Ключ адресата в сыром payload пуша (Sygnal мержит `pusher.data.default_payload`
/// в top-level FCM data / APNs userInfo; `PushNotification.fromJson` — whitelist и
/// этот ключ теряет, поэтому читаем его из сырой карты ДО парсинга).
const pushClientNameKey = 'client_name';

/// Ключ capability в `default_payload` pusher-а: клиент умеет тихий
/// clearing-пуш «почисти шторку» (howItWoks/pushes.md §21).
const pushClearCapabilityKey = 'liza_clear_v';

/// Маркер clearing-пуша в payload (ставит Sygnal).
const pushClearMarkerKey = 'liza_clear';

/// Метка конкретного clearing-пуша (ставит iOS-натив): по ней `clearingDone`
/// отпускает фоновое окно именно этого пуша.
const pushClearIdKey = 'liza_clear_id';

/// Тихий пуш «почисти шторку» — не уведомление о событии.
bool isClearingPush(Map<dynamic, dynamic> raw) {
  final marker = raw[pushClearMarkerKey];
  return marker == 1 || marker == '1' || marker == true;
}

String? pushClientNameFromRaw(Map<dynamic, dynamic>? raw) {
  final v = raw?[pushClientNameKey];
  return v is String && v.isNotEmpty ? v : null;
}

/// [client] — явный адресат (одноклиентный вызов, тесты); [clients] — все
/// залогиненные клиенты устройства, адресат выбирается `clientForPush` по
/// [clientName] из сырого payload / комнате. Ни того ни другого (фоновый isolate)
/// → клиенты поднимаются из `ClientManager`.
Future<void> pushHelper(
  PushNotification notification, {
  Client? client,
  List<Client>? clients,
  String? clientName,
  L10n? l10n,
  String? activeRoomId,
  String? activeClientName,
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
  bool useNotificationActions = true,
}) async {
  try {
    await _tryPushHelper(
      notification,
      client: client,
      clients: clients,
      clientName: clientName,
      l10n: l10n,
      activeRoomId: activeRoomId,
      activeClientName: activeClientName,
      flutterLocalNotificationsPlugin: flutterLocalNotificationsPlugin,
      useNotificationActions: useNotificationActions,
    );
  } catch (e, s) {
    Logs().e('Push Helper has crashed! Writing into temporary file', e, s);

    l10n ??= await lookupL10n(PlatformDispatcher.instance.locale);
    flutterLocalNotificationsPlugin.show(
      notification.roomId?.hashCode ?? 0,
      l10n.newMessageInLiza,
      l10n.openAppToReadMessages,
      NotificationDetails(
        iOS: const DarwinNotificationDetails(
          sound: 'liza_ding.aiff',
          presentSound: true,
          presentAlert: true,
          presentBadge: true,
          presentBanner: true,
          presentList: true,
        ),
        android: AndroidNotificationDetails(
          AppConfig.pushNotificationsChannelId,
          l10n.incomingMessages,
          // Крэш-фолбэк: клиентское число если клиент есть, иначе не ставим
          // (не сырое серверное counts.unread — оно раздувает бейдж).
          number: client == null ? null : AppBadge.visibleUnreadCount(client),
          ticker: l10n.unreadChatsInApp(
            AppSettings.applicationName.value,
            (notification.counts?.unread ?? 0).toString(),
          ),
          importance: Importance.high,
          priority: Priority.max,
          shortcutId: notification.roomId,
        ),
      ),
    );
    rethrow;
  }
}

Future<void> _tryPushHelper(
  PushNotification notification, {
  Client? client,
  List<Client>? clients,
  String? clientName,
  L10n? l10n,
  String? activeRoomId,
  String? activeClientName,
  required FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
  bool useNotificationActions = true,
}) async {
  final isBackgroundMessage = client == null && clients == null;
  final updateReadOnly = await UpdatePolicyController.readOnlyAnywhere(
    background: isBackgroundMessage,
  );
  Logs().v(
    'Push helper has been started (background=$isBackgroundMessage).',
    notification.toJson(),
  );

  // Адресат — ДО getEventByPushNotification: на чужом клиенте тот падает в
  // generic-баннер. Явный [client] (одноклиентный вызов) имеет приоритет.
  final allClients = client != null
      ? [client]
      : (clients ??
            await ClientManager.getClients(
              initialize: false,
              store: await AppSettings.init(),
            ));
  client ??= clientForPush(
    clients: allClients,
    clientName: clientName,
    roomId: notification.roomId,
    senderId: notification.sender,
  );
  // Бейдж иконки и App Group пишет ОДИН фиксированный клиент (первый) — иначе при
  // мультиаккаунте число мигало бы между аккаунтами «последним писателем».
  final badgeClient = allClients.first;
  final isBadgeClient = identical(client, badgeClient) ||
      client.clientName == badgeClient.clientName;

  // Check if user is currently viewing the room that sent the notification.
  // Like Liza: play sound + haptic but don't show a banner. «Активная»
  // комната принадлежит активному клиенту: та же комната у ДРУГОГО аккаунта
  // (личный чат между своими аккаунтами) баннер не глушит.
  // «Смотрит на чат» — тот же предикат, что у квитанции (readableForeground):
  // баннер глушим только из окна в фокусе, иначе квитанция и баннер расходятся.
  final isInActiveRoom = pushInActiveRoomFor(
    roomId: notification.roomId,
    activeRoomId: activeRoomId,
    activeClientName: activeClientName,
    clientName: client.clientName,
    resumed:
        readableForeground(
          lifecycle: WidgetsBinding.instance.lifecycleState,
          isDesktop: PlatformInfos.isDesktop,
          screenLocked: ScreenLockState.isLocked,
        ) ==
        ReadableForeground.full,
  );

  final event = await client.getEventByPushNotification(
    notification,
    storeInDatabase: false,
  );

  if (event == null) {
    // LABA-2354: различаем ДВА разных случая, оба дают event == null.
    //  1. Настоящий clearing-indicator — counts-only пуш БЕЗ event_id: сервер
    //     сообщает новое число непрочитанных, чтобы синхронизировать бейдж и
    //     снять уведомления уже прочитанных комнат.
    //  2. Пуш С event_id, но резолвер вернул null. По коду SDK это бывает,
    //     когда нет room_id ЛИБО событие уже помечено прочитанным
    //     (getEventByPushNotification: null при eventId==null||roomId==null или
    //     returnNullIfSeen). Не трактуем это как clearing — иначе очистка гасит
    //     только что показанный нативный баннер (на macOS баннер рисует
    //     AppDelegate.willPresent, а эта ветка могла бы его снять). Осознанный
    //     trade-off: узкий кейс «прочитано на другом устройстве» больше не
    //     снимает баннер этим путём (см. RL «Ловушки»); зато не роняем реальные
    //     уведомления. Такой пуш просто пропускаем.
    if (notification.eventId != null) {
      Logs().v(
        'Push event with event_id could not be resolved yet — not a clearing '
        'indicator, skipping notification cleanup.',
      );
      return;
    }
    Logs().v('Notification is a clearing indicator.');
    // cancelAll — только когда аккаунт на устройстве один: при мультиаккаунте
    // clearing одного аккаунта (unread=0) снёс бы уведомления соседа.
    if (allClients.length == 1 &&
        (notification.counts?.unread == null ||
            notification.counts?.unread == 0)) {
      await flutterLocalNotificationsPlugin.cancelAll();
    } else {
      // Make sure client is fully loaded and synced before dismiss notifications:
      await client.roomsLoading;
      // Таймаут обязателен: в фоновом изоляте без ограничения времени
      // замороженный/недоступный Synapse подвесил бы clearing-ветку целиком.
      await client.oneShotSync().timeout(
        const Duration(seconds: 8),
        onTimeout: () {},
      );
      final activeNotifications = await flutterLocalNotificationsPlugin
          .getActiveNotifications();
      final ownClientName = client.clientName;
      for (final activeNotification in activeNotifications) {
        final notificationId = activeNotification.id;
        if (notificationId == null) continue;
        // Чужое уведомление (payload другого аккаунта) не трогаем.
        final rawPayload = activeNotification.payload;
        final ownerName = rawPayload == null
            ? null
            : LizaPushPayload.fromString(rawPayload).clientName;
        if (ownerName != null && ownerName != ownClientName) continue;
        final room = client.rooms.singleWhereOrNull(
          (room) =>
              pushNotificationId(ownClientName, room.id) == notificationId ||
              // legacy id без скоупа аккаунта (уведомления прежней сборки)
              room.id.hashCode == notificationId,
        );
        // При мультиаккаунте уведомление без payload и без совпавшей комнаты —
        // неизвестного владельца: не гасим (консервативно).
        if (room == null && ownerName == null && allClients.length > 1) {
          continue;
        }
        // Тот же инвариант видимости, что у бейджа (countsTowardAppBadge =
        // !isHiddenChat && isUnreadOrInvited): нотификацию скрытой комнаты
        // (stories/обсуждение канала) тоже гасим — её нельзя открыть и
        // «прочитать», иначе баннер завис бы неснимаемым, как фантомный бейдж.
        if (room == null || !room.countsTowardAppBadge) {
          flutterLocalNotificationsPlugin.cancel(notificationId);
        }
      }
    }
    return;
  }
  // Бейдж на iOS/macOS — КЛИЕНТ единственный авторитет числа. На синканном
  // клиенте refreshFrom пересчитывает по видимым непрочитанным и персистит
  // число в App Group (его читает NSE при закрытом приложении). На НЕсинканном
  // фоновом клиенте НЕ трогаем бейдж сырым серверным counts.unread — оно
  // считает topology-скрытые и server-stuck комнаты, которые клиент исключает
  // (иначе вернём накопительную инфляцию; NSE уже показал последнее клиентское
  // число из App Group). См. RL-app-badge-native-visible-count.
  if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
    if (isBadgeClient && client.prevBatch != null) {
      await AppBadge.refreshFrom(client);
    }
  }

  // Наблюдаемость дрейфа счётчиков (ВТОРИЧНЫЙ human-facing сигнал): серверное
  // push-payload counts.unread против СЫРОГО серверного числа непрочитанных комнат
  // после sync (комнаты с notificationCount>0 + приглашения — НЕ topology-filtered,
  // иначе поймали бы штатный зазор скрытых комнат). Расхождение = симптом серверной
  // грязи event_push_summary (корень инфляции бейджа). ТОЛЬКО читает — бейдж не
  // трогает (число ставит блок выше). Первичный, полный источник дрейфа — серверный
  // view analytics.push_summary_drift. См. RL-badge-drift-telemetry.
  final serverUnread = notification.counts?.unread;
  if (serverUnread != null && client.prevBatch != null) {
    final rawServerCount = client.rooms
            .where((r) => r.membership == Membership.invite)
            .length +
        client.rooms.where((r) => r.notificationCount > 0).length;
    Monitoring.reportBadgeDrift(
      pushUnread: serverUnread,
      postSyncRaw: rawServerCount,
    );
  }

  Logs().v('Push helper got notification event of type ${event.type}.');

  // Пост Liza News для других платформ. Sygnal такой пуш не шлёт, но легаси-
  // pusher (iOS/macOS неразличимы) и старый Sygnal могут его доставить.
  if (event.isHiddenByNewsAudience) {
    Logs().v('Push is a Liza News post for other platforms. Do not display.');
    return;
  }

  if (event.type.startsWith('m.call')) {
    // make sure bg sync is on (needed to update hold, unhold events)
    // prevent over write from app life cycle change
    client.backgroundSync = true;
  }

  if (event.type == EventTypes.CallHangup) {
    client.backgroundSync = false;
  }

  if (event.type.startsWith('m.call') && event.type != EventTypes.CallInvite) {
    Logs().v('Push message is a m.call but not invite. Do not display.');
    return;
  }

  if ((event.type.startsWith('m.call') &&
          event.type != EventTypes.CallInvite) ||
      event.type == 'org.matrix.call.sdp_stream_metadata_changed') {
    Logs().v('Push message was for a call, but not call invite.');
    return;
  }

  l10n ??= await L10n.delegate.load(PlatformDispatcher.instance.locale);
  final matrixLocals = MatrixLocals(l10n);

  // Calculate the body
  //
  // В чате с запретом сохранения контента тело в пуш не кладём: шторка и экран
  // блокировки — ДРУГОЕ окно, `FLAG_SECURE` чата на них не распространяется, и
  // текст защищённого сообщения оказался бы скриншотабелен в обход всех гейтов
  // (LABA-2541). Тот же плейсхолдер, что и для нерасшифрованного события.
  final rawBody = event.type == EventTypes.Encrypted || event.room.isContentProtected
      ? l10n.newMessageInLiza
      : await event.calcLocalizedBody(
          matrixLocals,
          plaintextBody: !event.isForcedListArtifactBody,
          withSenderNamePrefix: false,
          hideReply: true,
          hideEdit: true,
          removeMarkdown: !event.isForcedListArtifactBody,
        );
  final body = stripMatrixMentions(rawBody, event.room);

  // The person object for the android message style notification
  final avatar = event.room.avatar;
  final senderAvatar = event.room.isDirectChat
      ? avatar
      : event.senderFromMemoryOrFallback.avatarUrl;

  Uint8List? roomAvatarFile, senderAvatarFile;
  try {
    roomAvatarFile = avatar == null
        ? null
        : await client
              .downloadMxcCached(
                avatar,
                thumbnailMethod: ThumbnailMethod.crop,
                width: notificationAvatarDimension,
                height: notificationAvatarDimension,
                animated: false,
                isThumbnail: true,
                rounded: true,
              )
              .timeout(const Duration(seconds: 3));
  } catch (e, s) {
    Logs().e('Unable to get avatar picture', e, s);
  }
  try {
    senderAvatarFile = event.room.isDirectChat
        ? roomAvatarFile
        : senderAvatar == null
        ? null
        : await client
              .downloadMxcCached(
                senderAvatar,
                thumbnailMethod: ThumbnailMethod.crop,
                width: notificationAvatarDimension,
                height: notificationAvatarDimension,
                animated: false,
                isThumbnail: true,
                rounded: true,
              )
              .timeout(const Duration(seconds: 3));
  } catch (e, s) {
    Logs().e('Unable to get avatar picture', e, s);
  }

  final id = pushNotificationId(client.clientName, notification.roomId);

  final senderName = event.senderFromMemoryOrFallback.calcDisplayname();
  // Show notification

  final newMessage = Message(
    body,
    event.originServerTs,
    Person(
      bot: event.messageType == MessageTypes.Notice,
      key: event.senderId,
      name: senderName,
      icon: senderAvatarFile == null
          ? null
          : ByteArrayAndroidIcon(senderAvatarFile),
    ),
  );

  final messagingStyleInformation = PlatformInfos.isAndroid
      ? await AndroidFlutterLocalNotificationsPlugin()
            .getActiveNotificationMessagingStyle(id)
      : null;
  messagingStyleInformation?.messages?.add(newMessage);

  final roomName = event.room.getLocalizedDisplayname(MatrixLocals(l10n));

  final notificationGroupId = event.room.isDirectChat
      ? 'directChats'
      : 'groupChats';
  final groupName = event.room.isDirectChat ? l10n.directChats : l10n.groups;

  final messageRooms = AndroidNotificationChannelGroup(
    notificationGroupId,
    groupName,
  );
  final roomsChannel = AndroidNotificationChannel(
    event.room.id,
    roomName,
    groupId: notificationGroupId,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannelGroup(messageRooms);
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(roomsChannel);

  final androidPlatformChannelSpecifics = AndroidNotificationDetails(
    AppConfig.pushNotificationsChannelId,
    l10n.incomingMessages,
    // Бейдж лаунчера Android = number нотификации. Клиент-авторитетное число
    // видимых непрочитанных (topology-фильтр), НЕ сырое серверное counts.unread
    // (оно раздувает бейдж скрытыми/stuck комнатами). На несинканном фоновом
    // клиенте visibleUnreadCount == null → number не ставим (не инфляцию).
    // См. RL-app-badge-native-visible-count. Число — от бейдж-клиента (первого),
    // а не от адресата пуша: единый писатель бейджа при мультиаккаунте.
    number: AppBadge.visibleUnreadCount(badgeClient),
    category: AndroidNotificationCategory.message,
    shortcutId: event.room.id,
    styleInformation:
        messagingStyleInformation ??
        MessagingStyleInformation(
          Person(
            name: senderName,
            icon: roomAvatarFile == null
                ? null
                : ByteArrayAndroidIcon(roomAvatarFile),
            key: event.roomId,
            important: event.room.isFavourite,
          ),
          conversationTitle: event.room.isDirectChat ? null : roomName,
          groupConversation: !event.room.isDirectChat,
          messages: [newMessage],
        ),
    ticker: stripMatrixMentions(
      event.calcLocalizedBodyFallback(
        matrixLocals,
        plaintextBody: !event.isForcedListArtifactBody,
        withSenderNamePrefix: !event.room.isDirectChat,
        hideReply: true,
        hideEdit: true,
        removeMarkdown: !event.isForcedListArtifactBody,
      ),
      event.room,
    ),
    importance: Importance.high,
    priority: Priority.max,
    groupKey: event.room.spaceParents.firstOrNull?.roomId ?? 'rooms',
    actions: event.type == EventTypes.RoomMember || !useNotificationActions
        ? null
        : <AndroidNotificationAction>[
            // Режим чтения обязательного обновления: ответить из шторки нельзя.
            if (!updateReadOnly)
              AndroidNotificationAction(
                LizaNotificationActions.reply.name,
                l10n.reply,
                inputs: [
                  AndroidNotificationActionInput(label: l10n.writeAMessage),
                ],
                cancelNotification: false,
                allowGeneratedReplies: true,
                semanticAction: SemanticAction.reply,
              ),
            AndroidNotificationAction(
              LizaNotificationActions.markAsRead.name,
              l10n.markAsRead,
              semanticAction: SemanticAction.markAsRead,
            ),
          ],
  );
  // iOS notification details: sound + banner + badge + avatar attachment.
  // flutter_local_notifications uses presentBanner/presentList on iOS 14+.
  final iosAvatarPath = await saveAvatarToTempFile(
    roomAvatarFile,
    notification.roomId ?? 'unknown',
  );
  final iOSPlatformChannelSpecifics = DarwinNotificationDetails(
    sound: 'liza_ding.aiff',
    presentSound: true,
    presentAlert: true,
    presentBadge: true,
    presentBanner: true,
    presentList: true,
    attachments: iosAvatarPath == null
        ? null
        : [DarwinNotificationAttachment(iosAvatarPath)],
  );
  final platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
    iOS: iOSPlatformChannelSpecifics,
    macOS: iOSPlatformChannelSpecifics,
  );

  final title = event.room.getLocalizedDisplayname(MatrixLocals(l10n));

  if (PlatformInfos.isAndroid && messagingStyleInformation == null) {
    await _setShortcut(event, l10n, title, roomAvatarFile);
  }

  // If user is in the active room: haptic only, no sound/banner (like Liza).
  if (isInActiveRoom) {
    Logs().v('User is in the active room. Playing haptic only.');
    HapticFeedback.mediumImpact();
    return;
  }

  // On iOS: NSE already shows the remote notification with sound/banner.
  // pushHelper only needs to add haptic feedback — skip showing a duplicate
  // local notification from flutter_local_notifications.
  if (PlatformInfos.isIOS) {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      HapticFeedback.mediumImpact();
    }
    Logs().v('Push helper: iOS notification handled by NSE, haptic only.');
    return;
  }

  // On macOS the native layer shows the banner: the NSE target
  // (NotificationServiceExtensionMacOS, added 2026-05) formats the remote push,
  // and AppDelegate.willPresent presents it. Инвариант «ровно один показывающий»
  // (LABA-2354): баннер рисует ТОЛЬКО нативный путь; Dart здесь остаётся
  // haptic-only и НЕ вызывает flutterLocalNotificationsPlugin.show — иначе на
  // одно сообщение выйдут ДВА баннера (нативный + Dart). Не снимать этот return.
  if (PlatformInfos.isMacOS) {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      HapticFeedback.mediumImpact();
    }
    Logs().v('Push helper: macOS notification handled by native layer, haptic only.');
    return;
  }

  await flutterLocalNotificationsPlugin.show(
    id,
    title,
    body,
    platformChannelSpecifics,
    payload: LizaPushPayload(
      client.clientName,
      event.room.id,
      event.eventId,
    ).toString(),
  );
  Logs().v('Push helper has been completed!');
}

class LizaPushPayload {
  final String? clientName, roomId, eventId;

  LizaPushPayload(this.clientName, this.roomId, this.eventId);

  factory LizaPushPayload.fromString(String payload) {
    final parts = payload.split('|');
    if (parts.length != 3) {
      return LizaPushPayload(null, null, null);
    }
    return LizaPushPayload(parts[0], parts[1], parts[2]);
  }

  @override
  String toString() => '$clientName|$roomId|$eventId';
}

/// Saves avatar bytes to a temporary file for notification attachments.
/// Returns the file path, or null if [avatarBytes] is null or write fails.
Future<String?> saveAvatarToTempFile(
  Uint8List? avatarBytes,
  String roomId,
) async {
  if (avatarBytes == null) return null;
  try {
    final tempDir = await getTemporaryDirectory();
    final file = File(
      '${tempDir.path}/notification_avatar_${Uri.encodeComponent(roomId)}.png',
    );
    await file.writeAsBytes(avatarBytes);
    return file.path;
  } catch (e, s) {
    Logs().e('Unable to save avatar to temp file for notification', e, s);
    return null;
  }
}

/// Creates a shortcut for Android platform but does not block displaying the
/// notification. This is optional but provides a nicer view of the
/// notification popup.
Future<void> _setShortcut(
  Event event,
  L10n l10n,
  String title,
  Uint8List? avatarFile,
) async {
  final flutterShortcuts = FlutterShortcuts();
  await flutterShortcuts.initialize(debug: !kReleaseMode);
  await flutterShortcuts.pushShortcutItem(
    shortcut: ShortcutItem(
      id: event.room.id,
      action: AppConfig.inviteLinkPrefix + event.room.id,
      shortLabel: title,
      conversationShortcut: true,
      icon: avatarFile == null ? null : base64Encode(avatarFile),
      shortcutIconAsset: avatarFile == null
          ? ShortcutIconAsset.androidAsset
          : ShortcutIconAsset.memoryAsset,
      isImportant: event.room.isFavourite,
    ),
  );
}
