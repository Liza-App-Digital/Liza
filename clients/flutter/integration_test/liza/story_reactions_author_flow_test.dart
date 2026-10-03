// LABA-2616: автор видит реакции на свою сторис.
//
// Автор (UI, testuser) публикует 3 сегмента. Зрители B и C (headless) ставят
// реакции так же, как реальный клиент зрителя (m.reaction-аннотация на
// сегмент): B ❤️ на 1-й и 😂 на 2-й, C 😂 на 1-й, а на 3-й C ставит ❤️ и
// меняет её на 👍 (redact + новая). Автор открывает свою сторис и видит под
// каждым сегментом отрисованный агрегат; тап по строке статистики открывает
// лист «Просмотры», сегмент не меняется, сторис стоит на паузе.
//
// AC:RL-stories-reactions/1 AC:RL-stories-reactions/3 AC:RL-stories-reactions/4
// AC:RL-stories-reactions/13
// ledger:RL-stories-reactions

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat_list/chat_list_body.dart';
import 'package:liza/pages/stories/story_viewer.dart';
import 'package:liza/pages/stories/story_viewers_sheet.dart';
import 'package:liza/utils/push_tap_navigation.dart';
import 'package:liza/utils/stories/stories_extension.dart';
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

Future<String> _react(
  E2eActor actor,
  String roomId,
  String eventId,
  String key,
) => actor.api.sendMessage(
  roomId,
  EventTypes.Reaction,
  'react-${DateTime.now().microsecondsSinceEpoch}',
  {
    'm.relates_to': {
      'rel_type': RelationshipTypes.reaction,
      'event_id': eventId,
      'key': key,
    },
  },
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'автор видит реакции и лист «Просмотры» — ledger:RL-stories-reactions',
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
        final s = segments.sublist(segments.length - 3);

        for (final viewer in [actorB, actorC]) {
          if (storyRoom.getParticipants().every((u) => u.id != viewer.userId)) {
            await storyRoom.invite(viewer.userId);
          }
          await viewer.joinRoom(storyRoom.id);
        }
        await _react(actorB, storyRoom.id, s[0].eventId, '❤️');
        await _react(actorB, storyRoom.id, s[1].eventId, '😂');
        await _react(actorC, storyRoom.id, s[0].eventId, '😂');
        final changed = await _react(actorC, storyRoom.id, s[2].eventId, '❤️');
        await actorC.api.redactEvent(
          storyRoom.id,
          changed,
          'redact-${DateTime.now().microsecondsSinceEpoch}',
        );
        await _react(actorC, storyRoom.id, s[2].eventId, '👍');

        navigatePushTap(
          client: client,
          router: LizaApp.router,
          roomId: storyRoom.id,
          eventId: s[0].eventId,
        );
        await tester.waitUntil(find.byType(StoryViewer));
        final viewer = tester.state<StoryViewerController>(
          find.byType(StoryViewer),
        );
        viewer.pause();

        // Ассерт по ОТРИСОВАННОЙ строке статистики — то, что видит автор.
        Set<String> shownReactions() {
          final row = find.byKey(const ValueKey('storyStatsRow'));
          if (row.evaluate().isEmpty) return const {};
          return {
            for (final e
                in find
                    .descendant(of: row, matching: find.byType(Text))
                    .evaluate())
              if ((e.widget as Text).data case final t? when t.contains(' ')) t,
          };
        }

        Future<void> expectShown(String eventId, Set<String> expected) async {
          // ignore: invalid_use_of_protected_member
          viewer.setState(
            () => viewer.index = viewer.segments.indexWhere(
              (e) => e.eventId == eventId,
            ),
          );
          final end = DateTime.now().add(const Duration(seconds: 30));
          while (!_sameSet(shownReactions(), expected) &&
              DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 500));
          }
          expect(shownReactions(), expected, reason: 'сегмент $eventId');
        }

        await expectShown(s[0].eventId, {'❤️ 1', '😂 1'});
        await expectShown(s[1].eventId, {'😂 1'});
        // Смена реакции: снятая ❤️ не учитывается.
        await expectShown(s[2].eventId, {'👍 1'});

        // Реальный тап по строке статистики — лист, а не перелистывание.
        await expectShown(s[0].eventId, {'❤️ 1', '😂 1'});
        final indexBefore = viewer.index;
        await tester.tap(find.byKey(const ValueKey('storyStatsRow')));
        await tester.waitUntil(find.byType(StoryViewersList));
        expect(viewer.index, indexBefore, reason: 'тап не листает сегмент');
        expect(viewer.isPaused, isTrue, reason: 'под листом сторис на паузе');
        expect(viewer.viewersSheetOpen, isTrue);
        final sheet = find.byType(StoryViewersList);
        final names = {
          for (final u in [actorB.userId, actorC.userId])
            storyRoom.unsafeGetUserFromMemoryOrFallback(u).calcDisplayname(),
        };
        for (final name in names) {
          expect(
            find.descendant(of: sheet, matching: find.text(name)),
            findsOneWidget,
            reason: 'зритель $name в листе',
          );
        }
        expect(
          find.descendant(of: sheet, matching: find.text('❤️')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sheet, matching: find.text('😂')),
          findsOneWidget,
        );
        Navigator.of(tester.element(sheet)).pop();
        await tester.pump(const Duration(seconds: 1));
        expect(viewer.viewersSheetOpen, isFalse);
      } finally {
        if (storyRoomId != null) {
          await actorB.leaveAndForget(storyRoomId);
          await actorC.leaveAndForget(storyRoomId);
        }
        await actorB.logout();
        await actorC.logout();
      }
    },
  );
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);
