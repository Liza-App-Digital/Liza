// ledger:RL-force-update-staged-policy
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/update_read_only_http_client.dart';

http.Request _req(String method, String path) =>
    http.Request(method, Uri.parse('https://hs.test$path'));

void main() {
  // AC:RL-force-update-staged-policy/10
  group('что считается записью в комнату', () {
    final blocked = {
      'сообщение': '/_matrix/client/v3/rooms/!a:hs/send/m.room.message/t1',
      'зашифрованное':
          '/_matrix/client/v3/rooms/!a:hs/send/m.room.encrypted/t2',
      'реакция': '/_matrix/client/v3/rooms/!a:hs/send/m.reaction/t3',
      'стикер': '/_matrix/client/v3/rooms/!a:hs/send/m.sticker/t4',
      'удаление': '/_matrix/client/v3/rooms/!a:hs/redact/\$e/t5',
      'r0-путь': '/_matrix/client/r0/rooms/!a:hs/send/m.room.message/t6',
    };
    blocked.forEach((name, path) {
      test('блокируется: $name', () {
        expect(
          UpdateReadOnlyHttpClient.isBlockedRoomWrite(_req('PUT', path)),
          isTrue,
        );
      });
    });

    final allowed = {
      'квитанция': (
        'POST',
        '/_matrix/client/v3/rooms/!a:hs/receipt/m.read/\$e',
      ),
      'read markers': ('POST', '/_matrix/client/v3/rooms/!a:hs/read_markers'),
      'typing': ('PUT', '/_matrix/client/v3/rooms/!a:hs/typing/@me:hs'),
      'to-device (ключи E2EE)': (
        'PUT',
        '/_matrix/client/v3/sendToDevice/m.room.encrypted/t7',
      ),
      'state-событие': (
        'PUT',
        '/_matrix/client/v3/rooms/!a:hs/state/m.room.name/',
      ),
      'ответ на звонок': (
        'PUT',
        '/_matrix/client/v3/rooms/!a:hs/send/m.call.answer/t8',
      ),
      'загрузка медиа': ('POST', '/_matrix/media/v3/upload'),
      'sync': ('GET', '/_matrix/client/v3/sync'),
    };
    allowed.forEach((name, req) {
      test('пропускается: $name', () {
        expect(
          UpdateReadOnlyHttpClient.isBlockedRoomWrite(_req(req.$1, req.$2)),
          isFalse,
        );
      });
    });
  });

  test('шифрованное событие пропускается только во время звонка', () {
    final enc = _req(
      'PUT',
      '/_matrix/client/v3/rooms/!a:hs/send/m.room.encrypted/t9',
    );
    addTearDown(() => UpdateReadOnlyHttpClient.isCallActive = () => false);
    UpdateReadOnlyHttpClient.isCallActive = () => false;
    expect(UpdateReadOnlyHttpClient.isBlockedRoomWrite(enc), isTrue);
    UpdateReadOnlyHttpClient.isCallActive = () => true;
    expect(UpdateReadOnlyHttpClient.isBlockedRoomWrite(enc), isFalse);
    // Обычное сообщение во время звонка по-прежнему режется.
    expect(
      UpdateReadOnlyHttpClient.isBlockedRoomWrite(
        _req('PUT', '/_matrix/client/v3/rooms/!a:hs/send/m.room.message/t10'),
      ),
      isTrue,
    );
  });

  test('вне режима чтения запрос уходит в сеть', () async {
    var hits = 0;
    final client = UpdateReadOnlyHttpClient(
      MockClient((_) async {
        hits++;
        return http.Response('{"event_id":"\$x"}', 200);
      }),
      readOnly: () => false,
    );
    final r = await client.send(
      _req('PUT', '/_matrix/client/v3/rooms/!a:hs/send/m.room.message/t1'),
    );
    expect(r.statusCode, 200);
    expect(hits, 1);
  });

  test('в режиме чтения — локальный отказ, сеть не трогается', () async {
    var hits = 0;
    final client = UpdateReadOnlyHttpClient(
      MockClient((_) async {
        hits++;
        return http.Response('{}', 200);
      }),
      readOnly: () => true,
    );
    final r = await http.Response.fromStream(
      await client.send(
        _req('PUT', '/_matrix/client/v3/rooms/!a:hs/send/m.room.message/t1'),
      ),
    );
    expect(hits, 0);
    expect(r.statusCode, 400);
    expect(r.body, contains(UpdateReadOnlyHttpClient.errcode));
  });

  test(
    'SDK: отказ даёт MatrixException не-M_FORBIDDEN (без диалога «нет прав»)',
    () async {
      final api = MatrixApi(
        homeserver: Uri.parse('https://hs.test'),
        accessToken: 't',
        httpClient: UpdateReadOnlyHttpClient(
          MockClient((_) async => http.Response('{}', 200)),
          readOnly: () => true,
        ),
      );
      await expectLater(
        api.sendMessage('!a:hs', 'm.room.message', 't1', {'body': 'x'}),
        throwsA(
          isA<MatrixException>()
              .having((e) => e.errcode, 'errcode', 'LIZA_UPDATE_REQUIRED')
              .having((e) => e.error, 'error', isNot(MatrixError.M_FORBIDDEN)),
        ),
      );
    },
  );
}
