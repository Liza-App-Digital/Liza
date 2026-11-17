// ignore_for_file: depend_on_referenced_packages

import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Client> prepareTestClient({
  bool loggedIn = false,
  Uri? homeserver,
  String id = 'Liza Widget Test',
  String clientName = 'Liza Widget Tests',
  FakeMatrixApi? httpClient,
  String userId = '@alice:example.invalid',
}) async {
  homeserver ??= Uri.parse('https://fakeserver.notexisting');
  final api = httpClient ?? FakeMatrixApi();
  // Мультиаккаунт-тесты: клиенты на РАЗНЫХ хоумсерверах (FakeMatrixApi отвечает
  // 404 неизвестному origin).
  api.servers.add(homeserver.origin);
  final client = Client(
    clientName,
    httpClient: api
      ..api['GET']!['/.well-known/matrix/client'] = (req) => {},
    verificationMethods: {
      KeyVerificationMethod.numbers,
      KeyVerificationMethod.emoji,
    },
    importantStateEvents: <String>{
      'im.ponies.room_emotes', // we want emotes to work properly
      // Держим в паре с client_manager.dart: иначе тесты проверяют не тот
      // sync-путь, что живёт в проде.
      'com.liza.chat.topology',
      'com.liza.chat.hidden_members',
      'com.liza.channel.no_forwards',
    },
    database: await MatrixSdkDatabase.init(
      'test',
      // Каждый fixture-клиент владеет своей БД, включая одинаковый memory path.
      database: await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      ),
      sqfliteFactory: databaseFactoryFfi,
    ),
    supportedLoginTypes: {
      AuthenticationTypes.password,
      AuthenticationTypes.sso,
    },
  );
  await client.checkHomeserver(homeserver);
  if (loggedIn) {
    await client.login(
      LoginType.mLoginToken,
      identifier: AuthenticationUserIdentifier(user: userId),
      password: '1234',
    );
  }
  return client;
}
