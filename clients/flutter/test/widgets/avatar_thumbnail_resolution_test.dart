import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/hexagon_clipper.dart';
import 'package:liza/widgets/mxc_image.dart';
import 'package:liza/widgets/story_avatar_ring.dart';

// ledger:RL-avatar-thumbnail-resolution
// Синтетические PNG: реальные Avatar → MxcImage → Matrix Client → HTTP →
// MemoryImage. Миниатюры воспроизводят размеры сервера без личных фотографий.
Uint8List _png(int width, int height, {int red = 30}) => img.encodePng(
  img.fill(
    img.Image(width: width, height: height, numChannels: 4),
    color: img.ColorRgba8(red, 120, 210, 255),
  ),
);

class _Server {
  _Server({this.landscape = false});

  final bool landscape;
  final calls = <Uri>[];
  final responses = <Uri, Uint8List>{};
  Future<void> Function(Uri)? beforeResponse;
  late Client client;

  Future<void> init() async {
    sqfliteFfiInit();
    client = Client(
      'avatar-resolution-test',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/_matrix/client/versions')) {
          return http.Response(
            jsonEncode({
              'versions': ['v1.11'],
            }),
            200,
          );
        }
        calls.add(request.url);
        if (!request.url.path.contains('/media/thumbnail/')) {
          return http.Response('{}', 404);
        }
        final requested = num.parse(request.url.queryParameters['width']!);
        final side = requested > 96 ? 240 : 96;
        final shortSide = requested > 96 ? 135 : 54;
        final crop = request.url.queryParameters['method'] == 'crop';
        final bytes = _png(
          crop || landscape ? side : shortSide,
          crop || !landscape ? side : shortSide,
          red: requested.round() % 256,
        );
        responses[request.url] = bytes;
        await beforeResponse?.call(request.url);
        return http.Response.bytes(
          bytes,
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
      database: await MatrixSdkDatabase.init(
        'avatar-resolution-test',
        database: await databaseFactoryFfi.openDatabase(':memory:'),
        sqfliteFactory: databaseFactoryFfi,
      ),
    );
    client.homeserver = Uri.parse('https://hs.example');
    client.accessToken = 'test-token';
    // SDK держит versions в AsyncCache на час. Загружаем внутри runAsync,
    // чтобы его служебный TTL не оставался pending timer в fake clock теста.
    await client.versionsResponse;
    addTearDown(client.dispose);
  }
}

final _uri = Uri.parse('mxc://avatar.example/synthetic');

Widget _host(
  _Server server, {
  double size = 65,
  double dpr = 3,
  StoryRingState? ring,
  bool hexagonal = false,
  bool noImage = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(devicePixelRatio: dpr),
    child: Center(
      child: Avatar(
        client: server.client,
        mxContent: noImage ? null : _uri,
        name: 'Тест',
        size: size,
        storyRing: ring,
        isHexagonal: hexagonal,
      ),
    ),
  ),
);

Uint8List? _shownBytes(WidgetTester tester) {
  final images = tester.widgetList<Image>(find.byType(Image));
  if (images.isEmpty) return null;
  final provider = images.last.image;
  return provider is MemoryImage ? provider.bytes : null;
}

// SQLite и декодер работают вне fake clock. Ожидание ограничено; бесконечный
// pumpAndSettle здесь скрывал бы сетевой зависон и backoff MxcImage.
Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue, reason: 'Загрузка должна завершиться за 1 с');
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(MxcImage.clearImageCache);
  tearDown(MxcImage.clearImageCache);

  for (final landscape in [false, true]) {
    for (final size in [65.0, 32.0]) {
      testWidgets('AC:RL-avatar-thumbnail-resolution/1 '
          '${landscape ? "альбом" : "портрет"} $size/DPR3: '
          'обе стороны показанного PNG достаточны', (tester) async {
        final server = _Server(landscape: landscape);
        await tester.runAsync(server.init);
        await tester.pumpWidget(_host(server, size: size));
        await _waitFor(tester, () => _shownBytes(tester) != null);

        final decoded = img.decodePng(_shownBytes(tester)!)!;
        expect(decoded.width, greaterThanOrEqualTo(size * 3));
        expect(decoded.height, greaterThanOrEqualTo(size * 3));
        expect(server.calls, hasLength(1));
        expect(server.calls.single.queryParameters['method'], 'crop');
        expect(
          num.parse(server.calls.single.queryParameters['width']!),
          size * 3,
        );
        expect(tester.getSize(find.byType(Avatar)), Size(size, size));
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('AC:RL-avatar-thumbnail-resolution/2 DPR1 → DPR3 '
      'перезагружает физическое разрешение', (tester) async {
    final server = _Server();
    await tester.runAsync(server.init);
    await tester.pumpWidget(_host(server, dpr: 1));
    await _waitFor(tester, () => _shownBytes(tester) != null);
    expect(img.decodePng(_shownBytes(tester)!)!.width, 96);

    await tester.pumpWidget(_host(server));
    await _waitFor(tester, () {
      final bytes = _shownBytes(tester);
      return bytes != null && img.decodePng(bytes)!.width >= 195;
    });
    expect(
      server.calls.map((uri) => num.parse(uri.queryParameters['width']!)),
      [65, 195],
    );
    expect(
      server.calls.map((uri) => uri.queryParameters['method']),
      everyElement('crop'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final changeRing in [false, true]) {
    testWidgets('AC:RL-avatar-thumbnail-resolution/2 поздний ответ после '
        '${changeRing ? "снятия кольца" : "увеличения размера"} '
        'не заменяет новые байты и RAM', (tester) async {
      final oldResponse = Completer<void>();
      final server = _Server();
      server.beforeResponse = (_) =>
          server.calls.length == 1 ? oldResponse.future : Future<void>.value();
      await tester.runAsync(server.init);
      try {
        await tester.pumpWidget(
          _host(
            server,
            size: changeRing ? 65 : 32,
            ring: changeRing ? StoryRingState.seen : null,
          ),
        );
        await _waitFor(tester, () => server.calls.length == 1);
        expect(_shownBytes(tester), isNull);
        await tester.pumpWidget(_host(server));
        await _waitFor(tester, () => _shownBytes(tester) != null);
        expect(server.calls, hasLength(2));
        final newBytes = server.responses[server.calls.last]!;
        expect(_shownBytes(tester), orderedEquals(newBytes));

        oldResponse.complete();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(_shownBytes(tester), orderedEquals(newBytes));

        // Новый State должен прочитать правильные байты также из RAM.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(_host(server));
        await _waitFor(tester, () => _shownBytes(tester) != null);
        expect(_shownBytes(tester), orderedEquals(newBytes));
        expect(server.calls, hasLength(2));
      } finally {
        if (!oldResponse.isCompleted) oldResponse.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
    });
  }

  testWidgets('AC:RL-avatar-thumbnail-resolution/2 старый RAM scale '
      'не используется квадратным аватаром', (tester) async {
    final server = _Server();
    await tester.runAsync(server.init);
    MxcImage.seedImageCache('${_uri}_65.0', _png(135, 240));
    await tester.pumpWidget(_host(server));
    await _waitFor(tester, () {
      final bytes = _shownBytes(tester);
      return bytes != null && img.decodePng(bytes)!.width >= 195;
    });
    expect(server.calls.single.queryParameters['method'], 'crop');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AC:RL-avatar-thumbnail-resolution/4 обычное вложение '
      'сохраняет scale', (tester) async {
    final server = _Server();
    await tester.runAsync(server.init);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 3),
          child: Center(
            child: MxcImage(
              client: server.client,
              uri: _uri,
              width: 65,
              height: 65,
            ),
          ),
        ),
      ),
    );
    await _waitFor(tester, () => _shownBytes(tester) != null);
    expect(server.calls.single.queryParameters['method'], 'scale');
    final decoded = img.decodePng(_shownBytes(tester)!)!;
    expect((decoded.width, decoded.height), (135, 240));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final noImage in [false, true]) {
    testWidgets('AC:RL-avatar-thumbnail-resolution/4 шестиугольник '
        '${noImage ? "без фото" : "с фото"} и кольцо сохраняют форму/размер', (
      tester,
    ) async {
      final server = _Server();
      await tester.runAsync(server.init);
      await tester.pumpWidget(
        _host(
          server,
          ring: StoryRingState.seen,
          hexagonal: true,
          noImage: noImage,
        ),
      );
      if (noImage) {
        expect(find.text('Т'), findsOneWidget);
        expect(server.calls, isEmpty);
      } else {
        await _waitFor(tester, () => _shownBytes(tester) != null);
        expect(server.calls.single.queryParameters['method'], 'crop');
        final requested = num.parse(
          server.calls.single.queryParameters['width']!,
        );
        final innerSize =
            65 - 2 * (StoryAvatarRing.ringWidth + StoryAvatarRing.gap);
        expect(requested, innerSize * 3);
      }
      expect(tester.getSize(find.byType(Avatar)), const Size(65, 65));
      final imageMaterial = tester.widget<Material>(
        find
            .ancestor(
              of: find.byType(MxcImage),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(imageMaterial.shape, isA<HexagonBorder>());
      expect(
        tester.widget<StoryAvatarRing>(find.byType(StoryAvatarRing)).hexagonal,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
