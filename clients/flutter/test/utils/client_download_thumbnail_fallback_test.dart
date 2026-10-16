import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/utils/client_download_content_extension.dart';

/// ledger:RL-media-stuck-load-watchdog AC:RL-media-stuck-load-watchdog/10
///
/// GlitchTip #2111: Synapse d3n8it упал по сегфолту посреди генерации превью
/// удалённых аватаров — запись о медиа осталась, превью нет. Без
/// dynamic_thumbnails сервер навсегда отвечает 400 на /thumbnail, клиент ретраил
/// тот же 400 и сдавался (`[media-stuck] reason=give-up`). Оригинал при этом цел
/// — 400 на превью должен давать фолбэк на /download.
void main() {
  final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, //
  ]);
  final mxc = Uri.parse('mxc://remote.example/abc');

  Future<(Client, List<String>)> clientWith({
    required int thumbnailStatus,
    required int downloadStatus,
  }) async {
    final calls = <String>[];
    final api = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/_matrix/client/versions')) {
        return http.Response(
          jsonEncode({
            'versions': ['v1.11'],
          }),
          200,
        );
      }
      if (path.contains('/media/thumbnail/')) {
        calls.add('thumbnail');
        return http.Response(
          jsonEncode({
            'errcode': 'M_UNKNOWN',
            'error': 'Cannot find any thumbnails',
          }),
          thumbnailStatus,
        );
      }
      if (path.contains('/media/download/')) {
        calls.add('download');
        return downloadStatus == 200
            ? http.Response.bytes(png, 200)
            : http.Response('{"errcode":"M_NOT_FOUND"}', downloadStatus);
      }
      return http.Response('{}', 404);
    });
    sqfliteFfiInit();
    final client = Client(
      'thumb-fallback-test',
      httpClient: api,
      database: await MatrixSdkDatabase.init(
        'thumb-fallback-test',
        database: await databaseFactoryFfi.openDatabase(':memory:'),
        sqfliteFactory: databaseFactoryFfi,
      ),
    );
    client.homeserver = Uri.parse('https://hs.example');
    client.accessToken = 'token';
    return (client, calls);
  }

  Future<Uint8List> fetch(Client c) => c.downloadMxcCached(
    mxc,
    width: 55,
    height: 55,
    isThumbnail: true,
    thumbnailMethod: ThumbnailMethod.scale,
  );

  test('400 на превью → отдаём оригинал с /download', () async {
    final (client, calls) = await clientWith(
      thumbnailStatus: 400,
      downloadStatus: 200,
    );
    expect(await fetch(client), png);
    expect(calls, ['thumbnail', 'download']);
  });

  test('404 на превью (медиа нет) — без фолбэка, ошибка', () async {
    final (client, calls) = await clientWith(
      thumbnailStatus: 404,
      downloadStatus: 200,
    );
    await expectLater(fetch(client), throwsException);
    expect(calls, ['thumbnail']);
  });

  test('400 на превью и оригинал недоступен — ошибка, а не мусор', () async {
    final (client, calls) = await clientWith(
      thumbnailStatus: 400,
      downloadStatus: 404,
    );
    await expectLater(fetch(client), throwsException);
    expect(calls, ['thumbnail', 'download']);
  });
}
