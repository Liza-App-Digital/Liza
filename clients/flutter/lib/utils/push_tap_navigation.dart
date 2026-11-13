import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import '../pages/stories/story_viewer.dart';
import 'push_probe_api.dart';
import 'push_tap_target.dart';

/// Открыт ли просмотрщик сторис, поднятый тапом уведомления. Гейт против
/// ДВОЙНОГО вьюера: `router.go('/rooms')` НЕ снимает императивный
/// `Navigator.push(StoryViewer)` поверх (go_router правит только свои матчи, а
/// URI остаётся `/rooms`), поэтому второй тап-в-тап иначе положил бы второй
/// StoryViewer поверх первого (ориентир Liza — один вьюер).
bool _pushTapStoryViewerOpen = false;

/// Единая навигация по тапу на уведомление — используется ОБЕИМИ точками входа
/// (`notificationTap` для foreground/local-notif и iOS cold-start NSE-тап в
/// `background_push`), чтобы не разъехались две копии логики (тот же принцип
/// «ссылки разбирает ровно один путь», что у deep-link'ов).
///
/// Сторис-комната → просмотрщик поверх `/rooms` (императивный push через
/// глобальный navigator, как отлаженный `_handleStoryLinkCode`: `StoryViewer`
/// завязан на `Matrix.of(context)`, а у обработчика тапа своего BuildContext
/// нет). Обычная комната/invite → прежний `router.go`.
void navigatePushTap({
  required Client client,
  required GoRouter router,
  required String roomId,
  String? eventId,
}) {
  // Тестовый пуш «Проверки уведомлений» (Р8): комната синтетическая.
  if (isTestPushEvent(eventId)) return;
  final target = resolvePushTapTarget(client, roomId, eventId);
  switch (target) {
    case RoomTapTarget(:final routePath):
      router.go(routePath);
    case StoryTapTarget(
        :final roomIds,
        :final initialIndex,
        :final initialEventId,
      ):
      // Тап-в-тап: если вьюер из прошлого тапа ещё открыт — не дублируем.
      if (_pushTapStoryViewerOpen) return;
      // Под низ уводим на список чатов (а НЕ на скрытую сторис-комнату), вьюер
      // пушим следующим кадром — когда `/rooms` уже смонтирован.
      router.go('/rooms');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pushTapStoryViewerOpen) return;
        final navContext = router.routerDelegate.navigatorKey.currentContext;
        if (navContext == null) {
          // Ранний cold-start: дерево ещё не готово — тап теряется (диагностика).
          Logs().w('[PushTap] navigatorContext=null, сторис-тап не открыт');
          return;
        }
        // location-gate: параллельный redirect (напр. неавторизован → /home)
        // мог увести с /rooms — не пушим вьюер поверх неожиданного экрана.
        if (router.routeInformationProvider.value.uri.path != '/rooms') {
          Logs().w('[PushTap] location != /rooms, сторис-тап пропущен');
          return;
        }
        _pushTapStoryViewerOpen = true;
        Navigator.of(navContext)
            .push(
              MaterialPageRoute(
                builder: (_) => StoryViewer(
                  roomIds: roomIds,
                  initialIndex: initialIndex,
                  initialEventId: initialEventId,
                ),
              ),
            )
            .whenComplete(() => _pushTapStoryViewerOpen = false);
      });
  }
}
