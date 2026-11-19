// ledger:RL-read-marker-ack-consistency
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat/chat_view.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/client_manager.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import 'e2e_actor.dart';
import 'e2e_config.dart';
import 'liza_flows.dart';

/// Реальный viewport сам отправляет квитанцию: без ответа из композера и
/// без прямого вызова ChatController.setReadMarker из теста.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('входящее в открытом чате прочитывается без ответа', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.show_no_google': false,
      ClientManager.clientNamespace: ['Liza ReadMarker E2E'],
    });
    final actorA = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userA);
    final actorB = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userB);
    final roomId = await actorB.createDirectChat(actorA.userId);
    try {
      await actorA.joinRoom(roomId);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final firstBody = 'read-open-$stamp';
      final firstId = await actorB.sendText(roomId, firstBody);
      app.main();
      await tester.ensureLizaHome();
      await tester.waitUntil(find.textContaining(firstBody));
      await tester.tap(find.textContaining(firstBody).first);
      await tester.waitUntil(find.byType(ChatView));
      await tester.waitUntil(
        find.textContaining(firstBody, findRichText: true),
      );
      final client = liza_matrix.Matrix.of(
        tester.element(find.byType(ChatView).first),
      ).client;
      final room = client.getRoomById(roomId)!;

      Future<void> expectRead(String eventId) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        var serverRead = false;
        while (DateTime.now().isBefore(deadline)) {
          try {
            final marker = await actorA.api.getAccountDataPerRoom(
              actorA.userId,
              roomId,
              'm.fully_read',
            );
            final sync = await actorA.api.sync(
              timeout: 0,
              filter: jsonEncode({
                'room': {
                  'rooms': [roomId],
                  'timeline': {'limit': 1},
                },
              }),
            );
            final count = sync
                .rooms
                ?.join?[roomId]
                ?.unreadNotifications
                ?.notificationCount;
            serverRead = marker['event_id'] == eventId && count == 0;
          } on MatrixException {
            // До первой квитанции account data может ещё не существовать.
          }
          await tester.pump(const Duration(milliseconds: 100));
          if (serverRead && room.notificationCount == 0) break;
        }
        // AC:RL-read-marker-ack-consistency/12
        expect(
          serverRead,
          isTrue,
          reason: 'Synapse подтвердил позицию и count=0',
        );
        expect(room.notificationCount, 0);
        expect(room.countsTowardAppBadge, isFalse);
      }

      await expectRead(firstId);

      final nextBody = 'read-live-$stamp';
      final nextId = await actorB.sendText(roomId, nextBody);
      await tester.waitUntil(find.textContaining(nextBody, findRichText: true));
      await expectRead(nextId);
    } finally {
      await actorA.leaveAndForget(roomId);
      await actorB.leaveAndForget(roomId);
      await actorB.logout();
      await actorA.logout();
    }
  });
}
