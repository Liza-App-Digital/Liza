// Явный local smoke с отдельным contract backend, не directory-discovered test.
// ledger:RL-push-causal-contract
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat/chat_view.dart';
import 'package:liza/utils/client_manager.dart';
import 'package:liza/utils/push_contract_session.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import 'e2e_actor.dart';
import 'e2e_config.dart';
import 'liza_flows.dart';

/// Меняет только сокет локального Bot API. Production URL и содержимое HTTP
/// не подменяются; collector, auth, payload, ACK и PostgreSQL остаются настоящими.
class _ContractFixtureConnection extends HttpOverrides {
  _ContractFixtureConnection(this.port);
  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (url, proxyHost, proxyPort) {
      if (url.scheme == 'http' && url.host == 'localhost' && url.port == 9997) {
        return Socket.startConnect('127.0.0.1', port);
      }
      return Socket.startConnect(proxyHost ?? url.host, proxyPort ?? url.port);
    };
    return client;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('живой Liza collector после UI-чтения отправляет contract batch', (
    tester,
  ) async {
    const port = int.fromEnvironment('E2E_PUSH_CONTRACT_PORT');
    if (port <= 0 || port > 65535) {
      throw StateError('Нужен порт изолированного local contract fixture');
    }
    final previous = HttpOverrides.current;
    HttpOverrides.global = _ContractFixtureConnection(port);
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.show_no_google': false,
      ClientManager.clientNamespace: ['Liza Push Contract E2E'],
    });
    final reader = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userA);
    final sender = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userB);
    final roomId = await sender.createDirectChat(reader.userId);
    Client? uiClient;
    try {
      await reader.joinRoom(roomId);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final first = 'contract-open-$stamp';
      await sender.sendText(roomId, first);
      app.main();
      await tester.ensureLizaHome();
      await tester.waitUntil(find.textContaining(first));
      await tester.tap(find.textContaining(first).first);
      await tester.waitUntil(find.byType(ChatView));
      await tester.waitUntil(find.textContaining(first, findRichText: true));
      final client = liza_matrix.Matrix.of(
        tester.element(find.byType(ChatView).first),
      ).client;
      uiClient = client;
      final room = client.getRoomById(roomId)!;
      final live = 'contract-live-$stamp';
      await sender.sendText(roomId, live);
      await tester.waitUntil(find.textContaining(live, findRichText: true));
      final deadline = DateTime.now().add(const Duration(seconds: 100));
      PushContractSession? session;
      // Сам scheduler захватывает и посылает данные. Прямой capture/read marker
      // из smoke не вызывается; серверная запись проверяется отдельно по binding.
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 250));
        session = PushContractSession.of(client);
      }
      // AC:RL-push-causal-contract/15
      expect(session, isNotNull);
      expect(session!.syncSequence, greaterThan(0));
      expect(room.notificationCount, 0);
      debugPrint(
        'CONTRACT_E2E_METADATA ${jsonEncode({'issuer': session.issuer, 'user': session.user, 'device': session.device, 'session_id': session.epoch, 'room_id': roomId, 'sync_sequence': session.syncSequence})}',
      );
    } finally {
      // Unmount до logout: Matrix.dispose ещё обращается к clients.first.
      await tester.pumpWidget(const SizedBox.shrink());
      if (uiClient != null) await uiClient.logout();
      await reader.leaveAndForget(roomId);
      await sender.leaveAndForget(roomId);
      await reader.logout();
      await sender.logout();
      HttpOverrides.global = previous;
    }
  });
}
