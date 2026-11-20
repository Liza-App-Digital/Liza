// Явный native local smoke; отдельный namespace, только локальные test actors.
// ledger:RL-edited-message-read-cursor
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat/chat_view.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/pages/chat_list/unread_bubble.dart';
import 'package:liza/utils/client_manager.dart';
import 'package:liza/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/builder.dart';
import 'package:liza/utils/unseen_messages.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import 'e2e_actor.dart';
import 'e2e_config.dart';
import 'liza_flows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native UI читает показанную правку, сервер хранит её receipt', (
    tester,
  ) async {
    if (!{'localhost', '127.0.0.1'}.contains(E2eConfig.homeserver.host)) {
      throw StateError('Разрешён только локальный fixture');
    }
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.show_no_google': false,
      ClientManager.clientNamespace: ['Liza Edited Cursor E2E'],
    });
    final reader = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userA);
    final sender = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userB);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final name = 'edited-cursor-$stamp';
    final roomId = await sender.createGroupChat([reader.userId], name: name);
    final returnName = 'edited-return-$stamp';
    final returnRoom = await sender.createGroupChat([
      reader.userId,
    ], name: returnName);
    final previousErrorHandler = FlutterError.onError;
    Client? uiClient;
    Client? peerClient;
    UnseenProjectionSubscription? peerProjection;
    OverlayEntry? peerOverlay;
    try {
      await reader.joinRoom(roomId);
      await reader.joinRoom(returnRoom);
      final body = 'original-$stamp';
      final original = await sender.sendText(roomId, body);
      app.main();
      await tester.ensureLizaHome();
      if (Platform.isMacOS) {
        final activation = await Process.run('/usr/bin/osascript', [
          '-l',
          'JavaScript',
          '-e',
          'ObjC.import("AppKit"); '
              r'$.NSRunningApplication.runningApplicationWithProcessIdentifier('
              '$pid).activateWithOptions(3); '
              r'$.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == '
              '$pid;',
        ]);
        debugPrint(
          'EDITED_CURSOR_FOCUS exit=${activation.exitCode} '
          'confirmed=${activation.stdout.toString().trim() == 'true'}',
        );
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.waitUntil(find.textContaining(name));
      await tester.tap(find.textContaining(name).first);
      await tester.waitUntil(find.byType(ChatView));
      Finder content(String text) => find.descendant(
        of: find.byType(ChatView),
        matching: find.textContaining(text, findRichText: true),
      );
      await tester.waitUntil(content(body));
      uiClient = liza_matrix.Matrix.of(
        tester.element(find.byType(ChatView).first),
      ).client;
      Directory? artifacts;
      Future<void> capture(String step) async {
        const requested = String.fromEnvironment('E2E_ARTIFACT_DIR');
        if (requested.isEmpty) return;
        // macOS App Sandbox: пишем в разрешённый temporary container.
        artifacts ??= await Directory(
          '${(await getTemporaryDirectory()).path}/read-dot-$stamp',
        ).create(recursive: true);
        final directory = artifacts!.path;
        debugPrint('EDITED_CURSOR_ARTIFACT_DIR $directory');
        await tester.pump(const Duration(milliseconds: 350));
        final started = DateTime.now().millisecondsSinceEpoch / 1000;
        RenderRepaintBoundary? boundary;
        tester.element(find.byType(ChatView).first).visitAncestorElements((e) {
          final render = e.findRenderObject();
          if (render is RenderRepaintBoundary) boundary = render;
          return true;
        });
        expect(boundary, isNotNull);
        final image = await boundary!.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$directory/native-$step.png').writeAsBytes(
          png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
        image.dispose();
        final fixtureRow = find.byWidgetPredicate(
          (widget) => widget is ChatListItem && widget.room.id == roomId,
        );
        final bubble = find.descendant(
          of: fixtureRow,
          matching: find.byType(UnreadBubble),
        );
        final container = find.descendant(
          of: bubble,
          matching: find.byType(AnimatedContainer),
        );
        final texts = find
            .descendant(
              of: find.byType(ChatView),
              matching: find.byType(RichText),
            )
            .evaluate()
            .map((e) => (e.widget as RichText).text.toPlainText())
            .join('\n');
        await File('$directory/native-$step-tree.json').writeAsString(
          jsonEncode({
            'nodes': [
              {'id': 'chat-content', 'text': texts},
              if (container.evaluate().length == 1)
                {'id': 'room-dot', 'value': tester.getSize(container).height},
            ],
          }),
        );
        await File('$directory/native-$step-step.json').writeAsString(
          jsonEncode({
            'id': step,
            'adapter': 'flutter-render',
            'provenance': 'fixture',
            'started_at': started,
            'ended_at': DateTime.now().millisecondsSinceEpoch / 1000,
            'scene': 'stable',
            'context': {
              'platform': 'macos',
              'app_id': 'liza-local-debug',
              'environment': 'local',
              'build': 'source-worktree',
            },
            'commands': [],
            'coordinate_space': {
              'units': 'px',
              'origin': [0, 0],
              'scale': 1,
              'space_id': 'route-render-boundary',
            },
          }),
        );
      }

      Future<void> serverReceipt(String eventId) async {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 150));
          // Независимая сессия получает собственную private/public receipt.
          // Никакого прямого вызова read marker или метода Controller.
          final sync = await reader.api.sync(
            timeout: 0,
            setPresence: PresenceType.offline,
            filter: jsonEncode({
              // Уникальный валидный filter исключает cached initial-sync ответ.
              'presence': {
                'not_types': [
                  'liza.fixture.${DateTime.now().microsecondsSinceEpoch}',
                ],
              },
              'room': {
                'rooms': [roomId],
                'timeline': {'limit': 1},
              },
            }),
          );
          final data = sync.toJson();
          final rooms = data['rooms'] as Map?;
          final join = rooms?['join'] as Map?;
          final room = join?[roomId] as Map?;
          final ephemeral = room?['ephemeral'] as Map?;
          for (final event in ephemeral?['events'] as List? ?? const []) {
            if (event['type'] != 'm.receipt') continue;
            final receipt = (event['content'] as Map)[eventId] as Map?;
            if (receipt == null) continue;
            for (final type in ['m.read', 'm.read.private']) {
              if ((receipt[type] as Map?)?.containsKey(reader.userId) ??
                  false) {
                return;
              }
            }
          }
        }
        final projected = uiClient!.getRoomById(roomId)!;
        final controller = tester
            .widget<ChatView>(find.byType(ChatView).first)
            .controller;
        debugPrint(
          'EDITED_CURSOR_RECEIPT_TIMEOUT '
          'target=${eventId == original ? 'original' : 'edit'} '
          'private_exact=${projected.receiptState.global.ownPrivate?.eventId == eventId} '
          'public_exact=${projected.receiptState.global.ownPublic?.eventId == eventId} '
          'fully_exact=${projected.fullyRead == eventId} '
          'timeline_live=${controller.timeline?.allowNewEvent} '
          'fragmented=${controller.timeline?.isFragmentedTimeline} '
          'lifecycle=${tester.binding.lifecycleState}',
        );
        fail('Сервер не подтвердил receipt именно показанной версии');
      }

      await capture('before');
      debugPrint(
        'EDITED_CURSOR_BASELINE lifecycle=${tester.binding.lifecycleState} '
        'matching_user=${uiClient.userID == reader.userId} '
        'preview_original=${uiClient.getRoomById(roomId)?.lastEvent?.eventId == original}',
      );
      await serverReceipt(original);
      // Вторая настоящая SDK-сессия того же пользователя: собственная SQLite,
      // обычный /sync. Timeline комнаты на B не открывается ни разу.
      final peer = Client(
        'Liza Edited Cursor Peer $stamp',
        database: await flutterMatrixSdkDatabaseBuilder('edited-peer-$stamp'),
      );
      peerClient = peer;
      peer.homeserver = E2eConfig.homeserver;
      peerProjection = UnseenProjectionSubscription(peer);
      await peer.login(
        AuthenticationTypes.password,
        identifier: AuthenticationUserIdentifier(user: E2eConfig.userA.name),
        password: E2eConfig.userA.password,
        initialDeviceDisplayName: 'Liza edited cursor peer fixture',
      );
      expect(peer.userID, uiClient.userID);
      expect(peer.deviceID, isNot(uiClient.deviceID));
      final peerRoom = peer.getRoomById(roomId)!;
      const peerKey = ValueKey('edited-cursor-peer-dot');
      peerOverlay = OverlayEntry(
        builder: (_) => Positioned(
          top: 75,
          right: 20,
          child: Material(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Peer SDK fixture'),
                StreamBuilder<SyncStatusUpdate>(
                  stream: peer.onSyncStatus.stream.where(
                    (update) => update.status == SyncStatus.finished,
                  ),
                  builder: (_, _) => UnreadBubble(room: peerRoom, key: peerKey),
                ),
              ],
            ),
          ),
        ),
      );
      Overlay.of(
        tester.element(find.byType(ChatView).first),
      ).insert(peerOverlay);
      final peerContainer = find.descendant(
        of: find.byKey(peerKey),
        matching: find.byType(AnimatedContainer),
      );
      Future<void> peerState(String eventId, {required bool unread}) async {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 150));
          if (peerRoom.lastEvent?.eventId == eventId &&
              peerContainer.evaluate().length == 1 &&
              (tester.getSize(peerContainer).height > 0) == unread) {
            return;
          }
        }
        fail('Вторая SDK-сессия не применила ожидаемый unread к виджету');
      }

      await tester.tap(find.textContaining(returnName).first);
      await tester.pump(const Duration(milliseconds: 500));
      final edited = 'edited-$stamp';
      final editId = await sender.api.sendMessage(
        roomId,
        'm.room.message',
        'edit-$stamp',
        {
          'msgtype': 'm.text',
          'body': '* $edited',
          'm.new_content': {'msgtype': 'm.text', 'body': edited},
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': original},
        },
      );
      await peerState(editId, unread: true);
      debugPrint('EDITED_CURSOR_PEER_BEFORE unread=true unopened=true');
      await capture('peer-unread');
      final row = find.byWidgetPredicate(
        (widget) => widget is ChatListItem && widget.room.id == roomId,
      );
      await tester.tap(row);
      await tester.waitUntil(content(edited));
      await serverReceipt(editId);
      await peerState(editId, unread: false);
      expect({
        peerRoom.receiptState.global.ownPrivate?.eventId,
        peerRoom.receiptState.global.ownPublic?.eventId,
      }, contains(editId));
      debugPrint(
        'EDITED_CURSOR_PEER_AFTER unread=false own_receipt_exact=true',
      );
      await tester.waitUntil(row);
      await tester.pump(const Duration(milliseconds: 700));
      final dot = find.descendant(of: row, matching: find.byType(UnreadBubble));
      expect(dot, findsOneWidget);
      final container = find.descendant(
        of: dot,
        matching: find.byType(AnimatedContainer),
      );
      expect(tester.getSize(container).height, 0);
      await capture('after');
      for (var i = 0; i < 3; i++) {
        await tester.waitUntil(find.textContaining(returnName));
        await tester.tap(find.textContaining(returnName).first);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(row);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.waitUntil(content(edited));
        expect(tester.getSize(container).height, 0);
      }
      await tester.tap(find.textContaining(returnName).first);
      await tester.pump(const Duration(milliseconds: 350));
      final unseen = await sender.sendText(roomId, 'unread-after-$stamp');
      await peerState(unseen, unread: true);
      expect(peerRoom.hasUnseenMessages, isTrue);
      expect(peerRoom.receiptState.global.ownPrivate?.eventId, isNot(unseen));
      expect(peerRoom.receiptState.global.ownPublic?.eventId, isNot(unseen));
      debugPrint('EDITED_CURSOR_PEER_NEWER unread=true receipt_not_newer=true');
      debugPrint(
        'EDITED_CURSOR_NATIVE_PASS ui=edited server=exact_receipt dot=0',
      );
    } finally {
      FlutterError.onError = previousErrorHandler;
      peerOverlay?.remove();
      peerProjection?.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      if (peerClient != null) {
        await peerClient.logout();
        await peerClient.dispose();
      }
      if (uiClient != null) await uiClient.logout();
      await reader.leaveAndForget(roomId);
      await sender.leaveAndForget(roomId);
      await reader.leaveAndForget(returnRoom);
      await sender.leaveAndForget(returnRoom);
      await reader.logout();
      await sender.logout();
    }
  });
}
