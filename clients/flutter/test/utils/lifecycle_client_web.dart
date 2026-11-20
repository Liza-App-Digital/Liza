// Браузерная пара test_client.dart только для Matrix lifecycle guard.
// Реальный IndexedDB SDK и те же WASM bindings, что использует приложение.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:web/web.dart' as web;

Future<void>? _cryptoReady;
var _databaseSequence = 0;

Future<Client> prepareTestClient({
  bool loggedIn = false,
  Uri? homeserver,
  String id = 'Liza Widget Test',
  String clientName = 'Liza Widget Tests',
  FakeMatrixApi? httpClient,
  String userId = '@alice:example.invalid',
}) async {
  assert(kIsWeb, 'Эта fixture должна работать в настоящем браузере');
  debugPrint('[web-lifecycle] start WASM $clientName');
  await (_cryptoReady ??= vod.init(wasmPath: '/browser/vodozemac/'));
  debugPrint('[web-lifecycle] WASM initialized; opening IndexedDB $clientName');
  homeserver ??= Uri.parse('https://fakeserver.notexisting');
  final api = httpClient ?? FakeMatrixApi();
  api.servers.add(homeserver.origin);
  final database = await MatrixSdkDatabase.init(
    'lifecycle-${DateTime.now().microsecondsSinceEpoch}-${_databaseSequence++}-$clientName',
    idbFactory: web.window.indexedDB,
  );
  // Наблюдаем настоящий browser storage отдельно от SDK quick cache:
  // созданная SDK база перечисляется браузером, а независимое соединение
  // читает пробную запись, сохранённую публичным SDK API в transaction.
  final names = (await web.window.indexedDB.databases().toDart).toDart;
  if (!names.any((entry) => entry.name == database.name)) {
    throw StateError('SDK база отсутствует в browser IndexedDB inventory');
  }
  const probeKey = 'com.liza.lifecycle.storage_probe';
  await database.transaction(
    () => database.storeAccountData(probeKey, {'client': clientName}),
  );
  final opened = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(database.name);
  request.onsuccess = ((web.Event _) {
    opened.complete(request.result as web.IDBDatabase);
  }).toJS;
  request.onerror = ((web.Event _) {
    opened.completeError(StateError('Independent IndexedDB open failed'));
  }).toJS;
  final independent = await opened.future;
  try {
    final read = Completer<Object?>();
    final transaction = independent.transaction(
      'box_account_data'.toJS,
      'readonly',
    );
    final stored = transaction
        .objectStore('box_account_data')
        .get(probeKey.toJS);
    stored.onsuccess = ((web.Event _) => read.complete(
      stored.result.dartify(),
    )).toJS;
    stored.onerror = ((web.Event _) {
      read.completeError(StateError('Independent IndexedDB read failed'));
    }).toJS;
    final value = await read.future;
    if (value is! Map || value['client'] != clientName) {
      throw StateError(
        'SDK запись не видна через independent IndexedDB connection',
      );
    }
  } finally {
    independent.close();
  }
  debugPrint(
    '[web-lifecycle] IndexedDB independent persisted read PASS $clientName',
  );
  final client = Client(
    clientName,
    httpClient: api..api['GET']!['/.well-known/matrix/client'] = (req) => {},
    verificationMethods: {
      KeyVerificationMethod.numbers,
      KeyVerificationMethod.emoji,
    },
    importantStateEvents: <String>{
      'im.ponies.room_emotes',
      'com.liza.chat.topology',
      'com.liza.chat.hidden_members',
      'com.liza.channel.no_forwards',
    },
    database: database,
    supportedLoginTypes: {
      AuthenticationTypes.password,
      AuthenticationTypes.sso,
    },
  );
  debugPrint('[web-lifecycle] IndexedDB open; client created $clientName');
  await client.checkHomeserver(homeserver);
  if (loggedIn) {
    await client.login(
      LoginType.mLoginToken,
      identifier: AuthenticationUserIdentifier(user: userId),
      password: '1234',
    );
  }
  if (loggedIn && !client.encryptionEnabled) {
    throw StateError('Browser lifecycle fixture требует загруженный Vodozemac');
  }
  return client;
}
