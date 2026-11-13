// ledger:RL-push-read-banner-sweep
//
// Р2 L1: NSE снимает прочитанные баннеры токеном аккаунта-адресата пуша.
// Писатель — BackgroundPush.nseCredentials → ApnsPushService.saveCredentials.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/apns_push_service.dart';
import 'package:liza/utils/background_push.dart';

import 'per_user_fake_api.dart';
import 'test_client.dart';

const _channel = MethodChannel('com.prodamus.laba.liza/apns');

Future<Client> _client(String name, String userId) {
  final host = userId.split(':').last;
  return prepareTestClient(
    loggedIn: true,
    clientName: name,
    userId: userId,
    homeserver: Uri.parse('https://$host'),
    httpClient: PerUserFakeMatrixApi(userId: userId, homeserverHost: host),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AC:RL-push-read-banner-sweep/4
  test(
    'креды каждого аккаунта по client_name, legacy — только текущий',
    () async {
      final a = await _client('Liza', '@a:a.example');
      final b = await _client('Liza-17', '@b:b.example');
      final creds = BackgroundPush.nseCredentials([a, b], b);
      expect(creds.map((c) => c.clientName), ['Liza', 'Liza-17']);
      expect(creds.map((c) => c.homeserverUrl), [
        'https://a.example',
        'https://b.example',
      ]);
      expect(creds.map((c) => c.accessToken), [a.accessToken, b.accessToken]);
      expect(creds.map((c) => c.legacy), [false, true]);
    },
  );

  test('аккаунт без токена в App Group не попадает', () async {
    final a = await _client('Liza', '@a:a.example');
    final out = await _client('Liza-2', '@c:c.example');
    out.accessToken = null;
    expect(
      BackgroundPush.nseCredentials([a, out], a).map((c) => c.clientName),
      ['Liza'],
    );
  });

  test(
    'saveCredentials передаёт clientName и признак legacy в натив',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'saveCredentials') calls.add(call);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, null),
      );
      await ApnsPushService().saveCredentials(
        homeserverUrl: 'https://h',
        accessToken: 't',
        clientName: 'Liza-17',
        legacy: false,
      );
      await ApnsPushService().saveCredentials(
        homeserverUrl: 'https://h',
        accessToken: 't',
      );
      expect(calls[0].arguments, {
        'homeserverUrl': 'https://h',
        'accessToken': 't',
        'clientName': 'Liza-17',
        'legacy': 'false',
      });
      expect(calls[1].arguments, {
        'homeserverUrl': 'https://h',
        'accessToken': 't',
        'legacy': 'true',
      });
    },
  );

  // AC:RL-push-read-banner-sweep/17
  test(
    'выход из аккаунта: натив получает client_name и оставшиеся аккаунты',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'removeCredentials') calls.add(call);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, null),
      );
      final a = await _client('Liza', '@a:a.example');
      final b = await _client('Liza-17', '@b:b.example');
      final remaining = BackgroundPush.nseRemainingClientNames([a, b], 'Liza');
      expect(remaining, ['Liza-17']);
      await ApnsPushService().removeCredentials('Liza', remaining: remaining);
      expect(calls.single.arguments, {
        'clientName': 'Liza',
        'remaining': ['Liza-17'],
      });
    },
  );
}
