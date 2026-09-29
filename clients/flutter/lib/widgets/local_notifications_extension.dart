import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:collection/collection.dart';
import 'package:desktop_notifications/desktop_notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart';
import 'package:matrix/matrix.dart';
import 'package:universal_html/html.dart' as html;

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/client_download_content_extension.dart';
import 'package:liza/utils/forced_list_artifact.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/news_audience.dart';
import 'package:liza/utils/push_client_resolver.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/push_helper.dart';
import 'package:liza/utils/read_marker_logic.dart';
import 'package:liza/utils/screen_lock_state.dart';
import 'package:liza/utils/strip_matrix_mentions.dart';
import 'package:liza/widgets/liza_app.dart';
import 'package:liza/widgets/matrix.dart';

/// Возраст события, после которого локальное уведомление уже не показываем:
/// догоняющий /sync приносит пачку пропущенного, и баннер о часовой давности
/// сообщении — шум, а не уведомление.
const _localNotificationMaxAge = Duration(minutes: 5);

extension LocalNotificationsExtension on MatrixState {
  static final html.AudioElement _audioPlayer = html.AudioElement()
    ..src = 'assets/assets/sounds/notification.ogg'
    ..load();

  void showLocalNotification(Event event) async {
    // Пост Liza News для других платформ: web/Windows/Linux/macOS показывают
    // уведомление из /sync мимо Sygnal, поэтому режем здесь, а не только там.
    if (event.isHiddenByNewsAudience) return;
    final roomId = event.room.id;
    // «Активная комната» принадлежит активному клиенту: та же комната у ДРУГОГО
    // своего аккаунта уведомление не глушит (общий предикат с нативным путём —
    // RL-push-active-room-native-suppress).
    if (pushInActiveRoomFor(
      roomId: roomId,
      activeRoomId: activeRoomId,
      activeClientName: client.clientName,
      clientName: event.room.client.clientName,
      // Тот же предикат, что у квитанции (readableForeground): в окне без
      // фокуса баннер показываем, и квитанция его больше не снимает.
      resumed:
          readableForeground(
            lifecycle: WidgetsBinding.instance.lifecycleState,
            isDesktop: PlatformInfos.isDesktop,
            screenLocked: ScreenLockState.isLocked,
          ) ==
          ReadableForeground.full,
    )) {
      return;
    }
    // Скрытую комнату (stories/обсуждение канала) нельзя открыть и «прочитать» —
    // её баннер завис бы неснимаемым, как фантомный бейдж. Тот же инвариант, что
    // у бейджа и у clearing-ветки push_helper.
    if (!event.room.countsTowardAppBadge &&
        event.room.membership != Membership.invite) {
      return;
    }
    // Догоняющий /sync после простоя эмитит onNotification по КАЖДОМУ
    // пропущенному событию — без этого гейта пользователь получил бы шквал
    // баннеров о старых сообщениях вместо одного свежего.
    final age = DateTime.now().difference(event.originServerTs);
    if (age > _localNotificationMaxAge) {
      Logs().v(
        '[Push] Skip local notification: event is ${age.inMinutes} min old',
        event.eventId,
      );
      return;
    }
    // APNs уже обогнал sync: баннер нарисовал натив — система у неактивной
    // Лизы, `willPresent` (`NativeBannerGate.banner`) у активной — либо натив
    // осознанно решил его не показывать. Второй, локальный, не нужен.
    if (backgroundPush?.isNativelyReceived(event.eventId) ?? false) {
      Logs().v(
        '[Push] Skip local notification: APNs already handled',
        event.eventId,
      );
      return;
    }
    // Отметку «показано» шлём ДО загрузки аватара (та ждёт сеть до 3 с): иначе
    // опоздавший APNs-пуш успеет проскочить нативный гейт и дать второй баннер.
    backgroundPush?.markLocallyShown(event.eventId);

    final title = event.room.getLocalizedDisplayname(
      MatrixLocals(L10n.of(context)),
    );
    final rawBody = await event.calcLocalizedBody(
      MatrixLocals(L10n.of(context)),
      withSenderNamePrefix:
          !event.room.isDirectChat ||
          event.room.lastEvent?.senderId == client.userID,
      plaintextBody: !event.isForcedListArtifactBody,
      hideReply: true,
      hideEdit: true,
      removeMarkdown: !event.isForcedListArtifactBody,
    );
    final body = stripMatrixMentions(rawBody, event.room);

    if (kIsWeb) {
      final avatarUrl = event.senderFromMemoryOrFallback.avatarUrl;
      Uri? thumbnailUri;

      if (avatarUrl != null) {
        const size = 128;
        const thumbnailMethod = ThumbnailMethod.crop;
        // Pre-cache so that we can later just set the thumbnail uri as icon:
        try {
          await client.downloadMxcCached(
            avatarUrl,
            width: size,
            height: size,
            thumbnailMethod: thumbnailMethod,
            isThumbnail: true,
            rounded: true,
          );
        } catch (e, s) {
          Logs().d('Unable to pre-download avatar for web notification', e, s);
        }

        thumbnailUri = await event.senderFromMemoryOrFallback.avatarUrl
            ?.getThumbnailUri(
              client,
              width: size,
              height: size,
              method: thumbnailMethod,
            );
      }

      _audioPlayer.play();

      html.Notification(
        title,
        body: body,
        icon: thumbnailUri?.toString(),
        tag: event.room.id,
      );
    } else if (Platform.isLinux) {
      final avatarUrl = event.room.avatar;
      final hints = [NotificationHint.soundName('message-new-instant')];

      if (avatarUrl != null) {
        const size = notificationAvatarDimension;
        const thumbnailMethod = ThumbnailMethod.crop;
        // Pre-cache so that we can later just set the thumbnail uri as icon:
        final data = await client.downloadMxcCached(
          avatarUrl,
          width: size,
          height: size,
          thumbnailMethod: thumbnailMethod,
          isThumbnail: true,
          rounded: true,
        );

        final image = decodeImage(data);
        if (image != null) {
          final realData = image.getBytes(order: ChannelOrder.rgba);
          hints.add(
            NotificationHint.imageData(
              image.width,
              image.height,
              realData,
              hasAlpha: true,
              channels: 4,
            ),
          );
        }
      }
      final notification = await linuxNotifications!.notify(
        title,
        body: body,
        replacesId: linuxNotificationIds[roomId] ?? 0,
        appName: AppSettings.applicationName.value,
        appIcon: 'liza',
        actions: [
          NotificationAction(
            DesktopNotificationActions.openChat.name,
            L10n.of(context).openChat,
          ),
          NotificationAction(
            DesktopNotificationActions.seen.name,
            L10n.of(context).markAsRead,
          ),
        ],
        hints: hints,
      );
      notification.action.then((actionStr) {
        var action = DesktopNotificationActions.values.singleWhereOrNull(
          (a) => a.name == actionStr,
        );
        if (action == null && actionStr == "default") {
          action = DesktopNotificationActions.openChat;
        }
        switch (action!) {
          case DesktopNotificationActions.seen:
            event.room.setReadMarker(
              event.eventId,
              mRead: event.eventId,
              public: AppSettings.sendPublicReadReceipts.value,
            );
            break;
          case DesktopNotificationActions.openChat:
            setActiveClient(event.room.client);

            LizaApp.router.go('/rooms/${event.room.id}');
            break;
        }
      });
      linuxNotificationIds[roomId] = notification.id;
    } else if (Platform.isMacOS) {
      final plugin = backgroundPush?.localNotificationsPlugin;
      if (plugin == null) {
        Logs().w('macOS: BackgroundPush plugin not initialized, skipping notification');
        return;
      }
      // Аватар и payload — от клиента ВЛАДЕЛЬЦА комнаты, а не от активного:
      // при мультиаккаунте активный ходит на чужой хоумсервер с чужим токеном
      // (401), а чужой clientName в payload увёл бы тап не в тот аккаунт.
      final roomClient = event.room.client;
      final avatarUrl = event.room.isDirectChat
          ? event.senderFromMemoryOrFallback.avatarUrl
          : event.room.avatar;
      String? avatarPath;
      if (avatarUrl != null) {
        try {
          final avatarBytes = await roomClient
              .downloadMxcCached(
                avatarUrl,
                width: notificationAvatarDimension,
                height: notificationAvatarDimension,
                thumbnailMethod: ThumbnailMethod.crop,
                isThumbnail: true,
                rounded: true,
              )
              .timeout(const Duration(seconds: 3));
          avatarPath = await saveAvatarToTempFile(avatarBytes, roomId);
        } catch (e, s) {
          Logs().d('Unable to download avatar for macOS notification', e, s);
        }
      }
      final attachments = avatarPath != null
          ? [DarwinNotificationAttachment(avatarPath)]
          : <DarwinNotificationAttachment>[];
      // Строка в liza.log — единственный след показа: без неё «баннера не было»
      // у пользователя не отличить от «был, но снят при открытии чата»
      // (разбор 2026-09-28, `pushes.md` §22). Метод async-void: необработанная
      // ошибка plugin.show раньше не попадала в лог вовсе.
      try {
        await plugin.show(
          // id со скоупом аккаунта: у двух своих аккаунтов в одной комнате
          // `roomId.hashCode` схлопнул бы уведомления в одно
          // (RL-push-multiaccount-routing AC-6), и `cancelNotification` гасил бы
          // не то — он ищет ровно `pushNotificationId`.
          pushNotificationId(roomClient.clientName, roomId),
          title,
          body,
          NotificationDetails(
            macOS: DarwinNotificationDetails(
              sound: 'liza_ding.aiff',
              presentSound: true,
              presentAlert: true,
              // Бейдж на macOS пишет ТОЛЬКО клиент (AppBadge.refreshFrom) по
              // видимым непрочитанным; уведомление его не трогает, иначе вернём
              // расхождение с App Group (RL-app-badge-native-visible-count).
              presentBadge: false,
              presentBanner: true,
              presentList: true,
              attachments: attachments,
              threadIdentifier: roomId,
            ),
          ),
          payload: LizaPushPayload(
            roomClient.clientName,
            event.room.id,
            event.eventId,
          ).toString(),
        );
        Logs().v('[Push] Local notification shown', event.eventId);
      } catch (e, s) {
        Logs().w('[Push] Local notification failed', e, s);
      }
    } else if (Platform.isWindows) {
      final plugin = backgroundPush?.localNotificationsPlugin;
      if (plugin == null) {
        Logs().w(
          'Windows: BackgroundPush plugin not initialized, skipping notification',
        );
        return;
      }
      await plugin.show(
        roomId.hashCode,
        title,
        body,
        const NotificationDetails(
          windows: WindowsNotificationDetails(),
        ),
        payload: LizaPushPayload(
          client.clientName,
          event.room.id,
          event.eventId,
        ).toString(),
      );
    }
  }
}

enum DesktopNotificationActions { seen, openChat }
