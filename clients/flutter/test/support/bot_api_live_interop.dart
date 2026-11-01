// ignore_for_file: depend_on_referenced_packages
// Явный live proof, не входит в обычный discovery *_test.dart.
// ledger:RL-bot-api-inline-queries
// AC:RL-bot-api-inline-queries/10
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:vodozemac/vodozemac.dart' as vod;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_delivery.dart';

/// Меняет только destination URL на операторский loopback fixture.
/// Ответы всегда настоящие; потеря уже успешного ответа моделирует обрыв сети.
class _LoopbackTransport extends http.BaseClient {
  final Uri target;
  final http.Client inner = http.Client();
  int selectRequests = 0;
  int ackRequests = 0;
  bool lostSelect = false;
  bool lostAck = false;

  _LoopbackTransport(this.target) {
    if (target.scheme != 'http' || target.host != '127.0.0.1') {
      throw StateError('Only the isolated loopback fixture is allowed');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final destination = target.replace(
      path: request.url.path,
      query: request.url.hasQuery ? request.url.query : null,
    );
    final forwarded = http.Request(request.method, destination)
      ..followRedirects = false
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    final response = await inner.send(forwarded);
    final select = request.url.path.endsWith('/select');
    final ack = request.url.path.endsWith('/ack');
    if (select) selectRequests++;
    if (ack) ackRequests++;
    if (response.statusCode == 200 &&
        ((select && !lostSelect) || (ack && !lostAck))) {
      await response.stream.drain<void>();
      if (select) lostSelect = true;
      if (ack) lostAck = true;
      throw http.ClientException('Intentional loss of committed HTTP response');
    }
    return response;
  }

  @override
  void close() => inner.close();
}

// Базовая реализация создаёт реальные сокеты вместо Flutter test HTTP400.
class _LiveHttpOverrides extends HttpOverrides {}

void main() {
  test(
    'production Flutter delivery over real Bot API and Matrix',
    () => HttpOverrides.runWithHttpOverrides(() async {
      const path = String.fromEnvironment('BOT_API_LIVE_CONFIG');
      if (path.isEmpty) {
        throw StateError('Explicit live fixture config required');
      }
      final config = jsonDecode(await File(path).readAsString()) as Map;
      final homeserver = Uri.parse(config['homeserver'] as String);
      if (homeserver.scheme != 'http' || homeserver.host != '127.0.0.1') {
        throw StateError(
          'Only the isolated Matrix loopback fixture is allowed',
        );
      }
      stdout.writeln('LIVE_PHASE crypto_init');
      await vod.init(libraryPath: config['crypto_directory'] as String);
      expect(vod.isInitialized(), isTrue);
      final matrixHttp = http.Client();
      final client = Client(
        'Liza live Bot API proof',
        httpClient: matrixHttp,
        database: await MatrixSdkDatabase.init(
          'live-proof',
          database: await databaseFactoryFfi.openDatabase(
            ':memory:',
            options: OpenDatabaseOptions(singleInstance: false),
          ),
          sqfliteFactory: databaseFactoryFfi,
        ),
      );
      final transport = _LoopbackTransport(
        Uri.parse(config['api_url'] as String),
      );
      BotInteractiveApi? api;
      try {
        client.backgroundSync = false;
        await client.init(
          newToken: config['access_token'] as String,
          newUserID: config['user_id'] as String,
          newHomeserver: homeserver,
          newDeviceID: config['device_id'] as String?,
          newDeviceName: 'Liza live Bot API proof',
        );
        final room = client.getRoomById(config['room_id'] as String);
        expect(
          room,
          isNotNull,
          reason: 'Real initial sync must contain the room',
        );
        expect(room!.encrypted, isFalse, reason: 'This proof covers plaintext');
        api = BotInteractiveApi(client, transport: transport);
        final bot = await api.resolve(mxid: config['bot_mxid'] as String);
        expect(bot?.supportsInteractive, isTrue);
        final sid = config['session_id'] as String;
        Future<Map<String, dynamic>> create(String suffix) async {
          final query = await api!.request(
            'POST',
            '/liza/interactive/query',
            body: {
              'kind': 'inline',
              'bot_mxid': bot!.mxid,
              'room_id': room.id,
              'session_id': sid,
              'query': '${config['query_prefix']}-$suffix',
            },
          );
          for (var i = 0; i < 100; i++) {
            final status = await api.request(
              'GET',
              '/liza/interactive/query/${query['query_id']}',
              query: {'session_id': sid},
            );
            if (status['status'] == 'answered') return status;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          throw StateError(
            'Live bot did not answer within the bounded deadline',
          );
        }

        final query = await create('deliver');
        var sends = 0;
        final delivery = BotInteractiveDelivery(
          api: api,
          queryId: query['query_id'] as String,
          sessionId: sid,
          resultId: 'live-article',
          isCurrent: () => true,
          send: (content, txid) {
            sends++;
            return room.sendEvent(content, txid: txid);
          },
        );
        expect(
          await delivery.deliver(),
          isFalse,
        ); // SELECT принят, ответ потерян.
        expect(sends, 0);
        expect(
          await delivery.deliver(),
          isFalse,
        ); // send + ACK принят, ответ потерян.
        final eventId = delivery.eventId;
        expect(eventId, isNotNull);
        expect(sends, 1);
        expect(await delivery.deliver(), isTrue); // только повтор ACK.
        expect(delivery.eventId, eventId);
        expect(sends, 1);
        expect(transport.selectRequests, 2);
        expect(transport.ackRequests, 2);

        final cancelled = await create('cancel');
        final cancel = await api.request(
          'POST',
          '/liza/interactive/query/${cancelled['query_id']}/cancel',
          body: {'session_id': sid},
        );
        expect(cancel['cancelled'], isTrue);
        final denied = BotInteractiveDelivery(
          api: api,
          queryId: cancelled['query_id'] as String,
          sessionId: sid,
          resultId: 'live-article',
          isCurrent: () => true,
          send: (content, txid) {
            sends++;
            return room.sendEvent(content, txid: txid);
          },
        );
        expect(await denied.deliver(), isFalse);
        expect(sends, 1);
        stdout.writeln('LIVE_PHASE plaintext_pass_encrypted_start');
        final encrypted = await _encryptedProof(client, config);
        await File(config['result_path'] as String).writeAsString(
          jsonEncode({
            'query_id': query['query_id'],
            'cancelled_query_id': cancelled['query_id'],
            'event_id': eventId,
            'send_calls': sends,
            'select_retries': 1,
            'ack_retries': 1,
            'scope': 'plaintext_and_e2ee',
            'encrypted': encrypted,
          }),
        );
      } finally {
        api?.dispose();
        transport.close();
        await client.dispose();
        matrixHttp.close();
      }
    }, _LiveHttpOverrides()),
    timeout: const Timeout(Duration(seconds: 150)),
  );
}

// AC:RL-bot-api-inline-queries-client/5
Future<Map<String, dynamic>> _encryptedProof(Client sender, Map config) async {
  final other = config['subscriber'] as Map;
  final network = http.Client();
  final receiver = Client(
    'Liza live encrypted recipient',
    httpClient: network,
    database: await MatrixSdkDatabase.init(
      'encrypted-recipient',
      database: await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      ),
      sqfliteFactory: databaseFactoryFfi,
    ),
  );
  final transport = _LoopbackTransport(Uri.parse(config['api_url'] as String));
  final api = BotInteractiveApi(sender, transport: transport);
  try {
    receiver.backgroundSync = false;
    await receiver.init(
      newToken: other['access_token'] as String,
      newUserID: other['user_id'] as String,
      newHomeserver: Uri.parse(other['homeserver'] as String),
      newDeviceID: other['device_id'] as String?,
      newDeviceName: 'Liza live encrypted recipient',
    );
    expect(sender.encryptionEnabled && receiver.encryptionEnabled, isTrue);
    final roomId = await sender.createRoom(
      name: 'Liza isolated encrypted proof',
      preset: CreateRoomPreset.privateChat,
      invite: [receiver.userID!],
      initialState: [
        StateEvent(
          type: EventTypes.Encryption,
          stateKey: '',
          content: {'algorithm': 'm.megolm.v1.aes-sha2'},
        ),
      ],
    );
    await receiver.joinRoom(roomId);
    Future<Room> joined(Client client) async {
      for (var i = 0; i < 300; i++) {
        await client.oneShotSync(timeout: Duration.zero);
        final room = client.getRoomById(roomId);
        if (room != null &&
            room.membership == Membership.join &&
            room.encrypted) {
          return room;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final last = client.getRoomById(roomId);
      throw StateError(
        'Encrypted room missing for ${client.userID}: ${last?.membership}/${last?.encrypted}',
      );
    }

    stdout.writeln('LIVE_PHASE encrypted_room_created');
    final room = await joined(sender);
    final recipientRoom = await joined(receiver);
    final sid = '${config['session_id']}-encrypted';
    final query = await api.request(
      'POST',
      '/liza/interactive/query',
      body: {
        'kind': 'inline',
        'bot_mxid': config['bot_mxid'],
        'room_id': roomId,
        'session_id': sid,
        'query': '${config['query_prefix']}-encrypted',
      },
    );
    for (var i = 0; i < 150; i++) {
      final status = await api.request(
        'GET',
        '/liza/interactive/query/${query['query_id']}',
        query: {'session_id': sid},
      );
      if (status['status'] == 'answered') break;
      if (i == 149) throw StateError('Encrypted query answer timeout');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    stdout.writeln('LIVE_PHASE encrypted_room_synced_query_answered');
    var sends = 0;
    final delivery = BotInteractiveDelivery(
      api: api,
      queryId: query['query_id'] as String,
      sessionId: sid,
      resultId: 'live-article',
      isCurrent: () => true,
      send: (content, txid) {
        sends++;
        return room.sendEvent(content, txid: txid);
      },
    );
    expect(await delivery.deliver(), isFalse);
    expect(sends, 0);
    expect(await delivery.deliver(), isFalse);
    expect(delivery.eventId, isNotNull);
    expect(await delivery.deliver(), isTrue);
    expect(sends, 1);
    final raw = await sender.getOneRoomEvent(roomId, delivery.eventId!);
    expect(raw.type, EventTypes.Encrypted);
    expect(raw.content['algorithm'], 'm.megolm.v1.aes-sha2');
    expect(raw.content['ciphertext'], isA<String>());
    expect(raw.content.containsKey('body'), isFalse);
    stdout.writeln('LIVE_PHASE ciphertext_verified_wait_decrypt');
    Event? decrypted;
    for (var i = 0; i < 300; i++) {
      await receiver.oneShotSync(timeout: Duration.zero);
      await sender.oneShotSync(timeout: Duration.zero);
      final event = await recipientRoom.getEventById(delivery.eventId!);
      if (event?.body == config['query_prefix']) {
        decrypted = event;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      decrypted?.body,
      config['query_prefix'],
      reason: 'Second real SDK must decrypt Megolm',
    );
    expect(decrypted?.senderId, sender.userID);
    stdout.writeln('LIVE_PHASE recipient_decrypted_pass');
    return {
      'room_id': roomId,
      'event_id': delivery.eventId,
      'query_id': query['query_id'],
      'sender': sender.userID,
      'recipient': receiver.userID,
      'send_calls': sends,
      'ciphertext_verified': true,
      'recipient_decrypted': true,
      'select_requests': transport.selectRequests,
      'ack_requests': transport.ackRequests,
    };
  } finally {
    api.dispose();
    await receiver.dispose();
    network.close();
  }
}
