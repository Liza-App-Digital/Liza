import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/utils/client_download_content_extension.dart';

/// ledger:RL-avatar-thumbnail-resolution AC:RL-avatar-thumbnail-resolution/3
///
/// Настоящий SDK fileStorageLocation: округлённые PNG уведомлений не должны
/// подменять квадратную серверную миниатюру ни после рестарта, ни при смене
/// порядка вызовов. Фикстуры синтетические, фотографии пользователей не нужны.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory cacheDirectory;
  late Client client;
  late Uint8List serverPng;
  late List<Uri> thumbnailRequests;
  late bool networkBlocked;
  final mxc = Uri.parse('mxc://remote.example/synthetic-avatar');

  Future<Client> openClient() async {
    final api = MockClient((request) async {
      if (networkBlocked) {
        fail('Повторное чтение должно обходиться без сети: ${request.url}');
      }
      if (request.url.path.endsWith('/_matrix/client/versions')) {
        return http.Response(
          jsonEncode({
            'versions': ['v1.11'],
          }),
          200,
        );
      }
      if (request.url.path.contains('/media/thumbnail/')) {
        thumbnailRequests.add(request.url);
        return http.Response.bytes(
          serverPng,
          200,
          headers: {'content-type': 'image/png'},
        );
      }
      fail('Неожиданный HTTP-запрос: ${request.url}');
    });
    return Client(
        'crop-disk-cache-test',
        httpClient: api,
        database: await MatrixSdkDatabase.init(
          'crop-disk-cache-test',
          database: await databaseFactoryFfi.openDatabase(':memory:'),
          sqfliteFactory: databaseFactoryFfi,
          fileStorageLocation: cacheDirectory.uri,
        ),
      )
      ..homeserver = Uri.parse('https://hs.example')
      ..accessToken = 'test-token';
  }

  Future<Uint8List> fetch({required bool rounded}) => client.downloadMxcCached(
    mxc,
    width: 128,
    height: 128,
    isThumbnail: true,
    thumbnailMethod: ThumbnailMethod.crop,
    animated: false,
    rounded: rounded,
  );

  void expectImage(Uint8List png, {required bool rounded}) {
    final decoded = image.decodePng(png);
    expect(decoded, isNotNull, reason: 'Результат должен быть валидным PNG');
    final size = rounded ? 128 : 240;
    expect(decoded!.width, size);
    expect(decoded.height, size);
    for (final corner in [
      (0, 0),
      (size - 1, 0),
      (0, size - 1),
      (size - 1, size - 1),
    ]) {
      // AC:RL-avatar-thumbnail-resolution/3
      expect(
        decoded.getPixel(corner.$1, corner.$2).a,
        rounded ? 0 : 255,
        reason: 'Угол $corner: raw непрозрачен, rounded прозрачен',
      );
    }
    expect(decoded.getPixel(size ~/ 2, size ~/ 2).a, 255);
    if (!rounded) {
      expect(png, orderedEquals(serverPng), reason: 'Raw — байты сервера');
    }
  }

  void expectCleanHttpRequest() {
    expect(thumbnailRequests, hasLength(1));
    // AC:RL-avatar-thumbnail-resolution/3
    expect(
      thumbnailRequests.single.queryParameters,
      {'width': '128', 'height': '128', 'method': 'crop', 'animated': 'false'},
      reason: 'Версия локального crop cache не уходит в HTTP query',
    );
  }

  Future<void> reopenWithoutNetwork() async {
    networkBlocked = true;
    await client.dispose();
    client = await openClient();
  }

  setUp(() async {
    cacheDirectory = await Directory.systemTemp.createTemp('liza-crop-cache-');
    serverPng = Uint8List.fromList(
      image.encodePng(
        image.Image(width: 240, height: 240, numChannels: 4)
          ..clear(image.ColorRgba8(30, 100, 210, 255)),
      ),
    );
    thumbnailRequests = [];
    networkBlocked = false;
    client = await openClient();
  });

  tearDown(() async {
    await client.dispose();
    await cacheDirectory.delete(recursive: true);
  });

  test('legacy rounded crop128 игнорируется при чтении raw crop128', () async {
    final legacyImage = image.Image(width: 128, height: 128, numChannels: 4)
      ..clear(image.ColorRgba8(30, 100, 210, 255));
    for (var y = 0; y < 128; y++) {
      for (var x = 0; x < 128; x++) {
        if ((x - 63.5) * (x - 63.5) + (y - 63.5) * (y - 63.5) > 64 * 64) {
          legacyImage.setPixelRgba(x, y, 0, 0, 0, 0);
        }
      }
    }
    final legacyPng = Uint8List.fromList(image.encodePng(legacyImage));
    // Именно прежний SDK-ключ, а не копия нового алгоритма ключевания.
    // ignore: deprecated_member_use
    final legacyKey = mxc.getThumbnail(
      client,
      width: 128,
      height: 128,
      method: ThumbnailMethod.crop,
      animated: false,
    );
    await client.database.storeFile(legacyKey, legacyPng, 0);
    expect(await client.database.getFile(legacyKey), orderedEquals(legacyPng));
    expectImage(legacyPng, rounded: true);

    // AC:RL-avatar-thumbnail-resolution/3
    expectImage(await fetch(rounded: false), rounded: false);
    expectCleanHttpRequest();

    await reopenWithoutNetwork();
    expectImage(await fetch(rounded: false), rounded: false);
    expectCleanHttpRequest();
  });

  for (final roundedFirst in [true, false]) {
    final order = roundedFirst ? 'rounded → raw' : 'raw → rounded';
    test('$order: raw на диске, оба результата верны после рестарта', () async {
      // URI, dimensions, method, animated одинаковы: меняется только rounded.
      expectImage(await fetch(rounded: roundedFirst), rounded: roundedFirst);
      expectImage(await fetch(rounded: !roundedFirst), rounded: !roundedFirst);
      expectCleanHttpRequest();

      final files = await cacheDirectory
          .list()
          .where((f) => f is File)
          .toList();
      expect(files, hasLength(1), reason: 'На диске один raw PNG, без маски');
      // AC:RL-avatar-thumbnail-resolution/3
      expectImage(await (files.single as File).readAsBytes(), rounded: false);

      await reopenWithoutNetwork();
      expectImage(await fetch(rounded: false), rounded: false);
      expectImage(await fetch(rounded: true), rounded: true);
      expectCleanHttpRequest();
    });
  }

  test(
    'ошибка декодирования rounded не отравляет диск и допускает повтор',
    () async {
      final validPng = serverPng;
      serverPng = Uint8List.sublistView(validPng, 0, 16);
      expect(looksLikeCacheableImage(serverPng), isTrue);

      await expectLater(fetch(rounded: true), throwsA(isA<Exception>()));
      expect(thumbnailRequests, hasLength(1));
      // AC:RL-avatar-thumbnail-resolution/3
      expect(
        await cacheDirectory.list().toList(),
        isEmpty,
        reason:
            'PNG с magic bytes, но без декодируемого изображения не сохраняется',
      );

      serverPng = validPng;
      expectImage(await fetch(rounded: true), rounded: true);
      expect(
        thumbnailRequests,
        hasLength(2),
        reason: 'Повтор получает исправленный PNG',
      );
      final files = await cacheDirectory
          .list()
          .where((f) => f is File)
          .toList();
      expect(files, hasLength(1));
      expectImage(await (files.single as File).readAsBytes(), rounded: false);
    },
  );
}
