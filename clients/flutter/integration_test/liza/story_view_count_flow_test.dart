// LABA-2617: счётчик просмотров у автора сторис.
//
// Автор (UI, testuser) публикует 3 сегмента. Зрители B и C (headless,
// testuser2/3) вступают в сторис-комнату и шлют read-маркеры так же, как это
// делает реальный клиент зрителя: /read_markers с m.read + m.read.private.
// B досматривает все три сегмента, C — только первый. Автор открывает свою
// сторис и видит на сегментах 1/2/3 соответственно 2/1/1, а после удаления
// последнего сегмента (на нём receipt B) — 2/1. Затем роли меняются: UI
// смотрит чужую сторис, и его публичный receipt доходит до автора.
//
// AC:RL-stories-view-count/10
// ledger:RL-stories-view-count

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat_list/chat_list_body.dart';
import 'package:liza/pages/stories/story_viewer.dart';
import 'package:liza/utils/push_tap_navigation.dart';
import 'package:liza/utils/stories/stories_extension.dart';
import 'package:liza/utils/stories/story_model.dart';
import 'package:liza/widgets/liza_app.dart';
import 'package:liza/widgets/matrix.dart';

import 'e2e_actor.dart';
import 'e2e_config.dart';
import 'liza_flows.dart';

// 1×1 PNG — валидное изображение для публикации сторис.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, //
  0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, //
  0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, //
  0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, //
  0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Future<void> _markViewed(E2eActor viewer, String roomId, String eventId) =>
    viewer.api.setReadMarker(
      roomId,
      mFullyRead: eventId,
      mRead: eventId,
      mReadPrivate: eventId,
    );

/// Последний публичный m.read [userId] в [roomId], как его видит автор [author]
/// по своему /sync. Ждёт, пока receipt дойдёт до [expected] (или таймаут).
Future<String?> _waitReceipt(
  E2eActor author,
  String roomId,
  String userId,
  String expected,
  WidgetTester tester,
) async {
  String? since;
  String? latest;
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(end)) {
    final sync = await author.api.sync(since: since, timeout: 1000);
    since = sync.nextBatch;
    for (final e in sync.rooms?.join?[roomId]?.ephemeral ?? <BasicEvent>[]) {
      if (e.type != 'm.receipt') continue;
      e.content.forEach((eventId, byType) {
        final users = (byType as Map)['m.read'] as Map?;
        if (users != null && users.containsKey(userId)) latest = eventId;
      });
    }
    if (latest == expected) return latest;
    await tester.pump(const Duration(milliseconds: 500));
  }
  return latest;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'счётчик просмотров растёт у автора — ledger:RL-stories-view-count',
    (tester) async {
      final actorB = await E2eActor.login(
        E2eConfig.homeserver,
        E2eConfig.userB,
      );
      final actorC = await E2eActor.login(
        E2eConfig.homeserver,
        E2eConfig.userC,
      );
      String? storyRoomId;
      String? bRoomId;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      try {
        app.main();
        await tester.ensureLizaHome(timeout: const Duration(seconds: 120));
        final ctx = tester.element(find.byType(ChatListViewBody));
        final client = Matrix.of(ctx).client;

        for (var i = 0; i < 3; i++) {
          await client.publishStory(
            file: MatrixImageFile(bytes: _png, name: 'story$i.png'),
            overlays: const [],
          );
        }
        final storyRoom = client.myStoriesRoom!;
        storyRoomId = storyRoom.id;

        var segments = <Event>[];
        for (var i = 0; i < 60 && segments.length < 3; i++) {
          segments = await client.activeStoriesOf(storyRoom);
          if (segments.length < 3) {
            await tester.pump(const Duration(milliseconds: 500));
          }
        }
        expect(segments.length, greaterThanOrEqualTo(3));
        final last3 = segments.sublist(segments.length - 3);

        for (final viewer in [actorB, actorC]) {
          if (storyRoom.getParticipants().every((u) => u.id != viewer.userId)) {
            await storyRoom.invite(viewer.userId);
          }
          await viewer.joinRoom(storyRoom.id);
        }
        for (final s in last3) {
          await _markViewed(actorB, storyRoom.id, s.eventId);
        }
        await _markViewed(actorC, storyRoom.id, last3.first.eventId);

        navigatePushTap(
          client: client,
          router: LizaApp.router,
          roomId: storyRoom.id,
          eventId: last3.first.eventId,
        );
        await tester.waitUntil(find.byType(StoryViewer));
        final viewer = tester.state<StoryViewerController>(
          find.byType(StoryViewer),
        );
        viewer.pause();

        // Ассерт по ОТРИСОВАННОМУ числу рядом с глазом — то, что видит автор.
        String? shownCount() {
          final eye = find.byIcon(Icons.remove_red_eye_outlined);
          if (eye.evaluate().isEmpty) return null;
          final text = find.descendant(
            of: find.ancestor(of: eye, matching: find.byType(Row)).first,
            matching: find.byType(Text),
          );
          return (text.evaluate().first.widget as Text).data;
        }

        Future<void> expectCount(String eventId, int expected) async {
          // ignore: invalid_use_of_protected_member
          viewer.setState(
            () => viewer.index = viewer.segments.indexWhere(
              (e) => e.eventId == eventId,
            ),
          );
          final end = DateTime.now().add(const Duration(seconds: 30));
          while (shownCount() != '$expected' && DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 500));
          }
          expect(shownCount(), '$expected', reason: 'сегмент $eventId');
        }

        await expectCount(last3[0].eventId, 2);
        await expectCount(last3[1].eventId, 1);
        await expectCount(last3[2].eventId, 1);

        // Сценарий QA 07.09: автор удаляет ПОСЛЕДНИЙ сегмент — на нём стоит
        // receipt B. B видел и первые два, его просмотр не должен пропасть.
        viewer.index = viewer.segments.indexWhere(
          (e) => e.eventId == last3[2].eventId,
        );
        await viewer.deleteCurrent();
        viewer.pause();
        await expectCount(last3[0].eventId, 2);
        await expectCount(last3[1].eventId, 1);

        // Фаза 2 — сторона зрителя: UI-клиент смотрит ЧУЖУЮ сторис настоящим
        // вьюером, и его публичный receipt должен дойти до автора.
        viewer.close();
        final closed = DateTime.now().add(const Duration(seconds: 10));
        while (find.byType(StoryViewer).evaluate().isNotEmpty &&
            DateTime.now().isBefore(closed)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(find.byType(StoryViewer), findsNothing);
        bRoomId = await actorB.api.createRoom(
          name: 'Stories - testuser2',
          preset: CreateRoomPreset.privateChat,
          creationContent: {
            'com.liza.stories': true,
            'com.liza.chat.type': 'stories',
          },
          invite: [client.userID!],
        );
        final mxc = await actorB.api.uploadContent(
          _png,
          filename: 'story.png',
          contentType: 'image/png',
        );
        final bSegments = <String>[];
        for (var i = 0; i < 3; i++) {
          bSegments.add(
            await actorB.api.sendMessage(
              bRoomId,
              'm.room.message',
              'v$i-$stamp',
              {
                'msgtype': 'm.image',
                'body': 'Story',
                'url': mxc.toString(),
                'info': {'mimetype': 'image/png', 'w': 1, 'h': 1},
                storyContentKey: StoryContent(
                  expiresTs: DateTime.now().millisecondsSinceEpoch + 3600000,
                  overlays: const [],
                ).toJson(),
              },
            ),
          );
        }
        await tester.waitUntil(find.byType(ChatListViewBody));
        final end = DateTime.now().add(const Duration(seconds: 30));
        while (client.getRoomById(bRoomId)?.membership != Membership.join &&
            DateTime.now().isBefore(end)) {
          await client.autoJoinStoryInvites();
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(client.getRoomById(bRoomId)?.membership, Membership.join);

        navigatePushTap(
          client: client,
          router: LizaApp.router,
          roomId: bRoomId,
          eventId: bSegments.first,
        );
        await tester.waitUntil(find.byType(StoryViewer));
        // Досматриваем все три сегмента (по ~5 с) — вьюер листает сам.
        final seen = await _waitReceipt(
          actorB,
          bRoomId,
          client.userID!,
          bSegments.last,
          tester,
        );
        expect(
          seen,
          bSegments.last,
          reason: 'публичный m.read зрителя дошёл до последнего сегмента',
        );
      } finally {
        if (storyRoomId != null) {
          await actorB.leaveAndForget(storyRoomId);
          await actorC.leaveAndForget(storyRoomId);
        }
        if (bRoomId != null) await actorB.leaveAndForget(bRoomId);
        await actorB.logout();
        await actorC.logout();
      }
    },
  );
}
