// ledger:RL-single-image-uncropped
// Настоящие MessageContent → ImageBubble → MxcImage → Image.memory.
// Подменена только граница получения байтов, рендер продукта не копируется.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/image_bubble.dart';
import 'package:liza/pages/chat/events/message_content.dart';
import 'package:liza/widgets/blur_hash.dart';
import 'package:liza/widgets/mxc_image.dart';

import '../../../utils/test_client.dart';

var _captureIndex = 0;

class _ImageEvent extends Event {
  final Uint8List bytes;
  final Uint8List? thumbnailBytes;
  final Completer<void>? loadGate;
  final List<bool> thumbnailRequests = [];

  _ImageEvent({
    required super.room,
    required this.bytes,
    this.thumbnailBytes,
    this.loadGate,
    required Object? info,
    bool sticker = false,
  }) : super(
         eventId: r'$image',
         senderId: '@sender:example.invalid',
         originServerTs: DateTime(2026, 11, 18),
         type: sticker ? EventTypes.Sticker : EventTypes.Message,
         content: {
           'msgtype': sticker ? MessageTypes.Sticker : MessageTypes.Image,
           'body': 'screenshot.png',
           'url': 'mxc://example.invalid/original',
           if (info != null) 'info': info,
         },
       );

  @override
  Future<bool> isAttachmentInLocalStore({bool getThumbnail = false}) async =>
      false;

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    void Function(int)? onDownloadProgress,
  }) async {
    thumbnailRequests.add(getThumbnail);
    await loadGate?.future;
    return MatrixImageFile(
      bytes: getThumbnail ? thumbnailBytes ?? bytes : bytes,
      name: 'screenshot.png',
      mimeType: 'image/png',
    );
  }
}

// Маркеры по серединам сторон: вне скруглений и плашки времени.
Future<Uint8List> _fixture(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  for (final (color, rect) in [
    (const Color(0xFFFF0000), const Rect.fromLTWH(.4, .02, .2, .1)),
    (const Color(0xFF00FF00), const Rect.fromLTWH(.4, .88, .2, .1)),
    (const Color(0xFF0000FF), const Rect.fromLTWH(.02, .4, .1, .2)),
    (const Color(0xFFFFFF00), const Rect.fromLTWH(.88, .4, .1, .2)),
  ]) {
    canvas.drawRect(
      Rect.fromLTRB(
        rect.left * width,
        rect.top * height,
        rect.right * width,
        rect.bottom * height,
      ),
      Paint()..color = color,
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<GlobalKey> _pump(
  WidgetTester tester,
  _ImageEvent event, {
  double availableWidth = 320,
  bool showTime = true,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: availableWidth,
              height: 320,
              child: Center(
                child: MessageContent(
                  event,
                  timeline: Timeline(
                    room: event.room,
                    chunk: TimelineChunk(events: [event]),
                  ),
                  textColor: Colors.black,
                  linkColor: Colors.blue,
                  borderRadius: BorderRadius.circular(12),
                  selected: false,
                  trailingTime: showTime
                      ? const Text('00:22', key: Key('time'))
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Image.memory декодирует асинхронно в реальном raster thread.
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  return key;
}

Future<void> _expectEdges(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final counts = [0, 0, 0, 0];
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      for (var i = 0; i < rgba.length; i += 4) {
        final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        if (r > 220 && g < 30 && b < 30) counts[0]++;
        if (g > 220 && r < 30 && b < 30) counts[1]++;
        if (b > 220 && r < 30 && g < 30) counts[2]++;
        if (r > 220 && g > 220 && b < 30) counts[3]++;
      }
      // Необязательные локальные кадры — для независимой визуальной приёмки.
      const output = String.fromEnvironment('IMAGE_FIT_EVIDENCE');
      if (output.isNotEmpty) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$output/${_captureIndex++}.png')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      }
    } finally {
      image.dispose();
    }
  });
  expect(
    counts,
    everyElement(greaterThan(0)),
    reason: 'верх/низ/лево/право: $counts',
  );
  expect(tester.takeException(), isNull);
  final size = tester.getSize(find.byType(ImageBubble));
  expect(size.width.isFinite && size.height.isFinite, isTrue);
  expect(size.width, greaterThan(0));
  expect(size.height, greaterThan(0));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Client client;
  late Room room;
  final fixtures = <(int, int), Uint8List>{};
  const shapes = [
    (576, 1280),
    (1280, 576),
    (512, 512),
    (100, 2000),
    (2000, 100),
  ];

  setUpAll(() async {
    client = await prepareTestClient();
    room = Room(id: '!render:example.invalid', client: client);
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    for (final (w, h) in shapes) {
      fixtures[(w, h)] = await _fixture(w, h);
    }
    fixtures[(100, 1000)] = await _fixture(100, 1000);
    fixtures[(1280, 100)] = await _fixture(1280, 100);
  });

  tearDownAll(() async {
    await client.dispose();
  });

  for (final (w, h) in shapes) {
    testWidgets('AC:RL-single-image-uncropped/1 missing_${w}x$h', (
      tester,
    ) async {
      final event = _ImageEvent(
        room: room,
        bytes: fixtures[(w, h)]!,
        info: null,
      );
      final key = await _pump(tester, event);
      await _expectEdges(tester, key);
      expect(
        tester.widget<MxcImage>(find.byType(MxcImage)).fit,
        BoxFit.contain,
      );
    });
  }

  const invalid = <Object>[
    {},
    {'w': 576},
    {'h': 1280},
    {'w': 0, 'h': 1280},
    {'w': 576, 'h': 0},
    {'w': 0, 'h': 0},
    {'w': -1, 'h': 1280},
    {'w': 576, 'h': -1},
    {'w': -1, 'h': -1},
    {'w': '576', 'h': '1280'},
    {'w': 576.0, 'h': 1280.0},
    {'w': true, 'h': 1280},
    {'w': 576, 'h': false},
    {'w': <int>[], 'h': 1280},
    {'w': 576, 'h': <String, int>{}},
    false,
    'invalid info',
    <int>[],
  ];
  for (var i = 0; i < invalid.length; i++) {
    testWidgets('AC:RL-single-image-uncropped/2 invalid_$i', (tester) async {
      final event = _ImageEvent(
        room: room,
        bytes: fixtures[(576, 1280)]!,
        info: invalid[i],
      );
      final key = await _pump(tester, event);
      await _expectEdges(tester, key);
      expect(tester.getSize(find.byType(ImageBubble)), const Size(256, 256));
    });
  }

  for (final width in [120.0, 180.0, 600.0]) {
    for (final shape in shapes) {
      testWidgets(
        'AC:RL-single-image-uncropped/3 width_${width}_${shape.$1}x${shape.$2}',
        (tester) async {
          final event = _ImageEvent(
            room: room,
            bytes: fixtures[shape]!,
            info: null,
          );
          final key = await _pump(tester, event, availableWidth: width);
          await _expectEdges(tester, key);
          expect(
            tester.getSize(find.byType(ImageBubble)).width,
            lessThanOrEqualTo(width),
          );
          expect(find.byKey(const Key('time')), findsOneWidget);
          tester.element(find.byType(MessageContent)).markNeedsBuild();
          await tester.pump();
          await _expectEdges(tester, key);
          expect(event.thumbnailRequests, [
            true,
          ], reason: 'rebuild не перезагружает байты');
        },
      );
    }
  }

  for (final (w, h, sticker, expected) in [
    (576, 1280, false, const Size(160, 256)),
    (1280, 100, false, const Size(256, 32)),
    (512, 512, false, const Size(256, 256)),
    (100, 1000, true, const Size(32, 128)),
    (1280, 100, true, const Size(128, 32)),
    (512, 512, true, const Size(128, 128)),
  ]) {
    testWidgets('AC:RL-single-image-uncropped/4 geometry_${w}x${h}_$sticker', (
      tester,
    ) async {
      final event = _ImageEvent(
        room: room,
        bytes: fixtures[(w, h)]!,
        info: {'w': w, 'h': h},
        sticker: sticker,
      );
      // Геометрия стикеров проверяется без времени: на коротком стикере
      // плашка сама закрывает центральные маркеры; это не обрезка fit.
      final key = await _pump(tester, event, showTime: false);
      expect(tester.getSize(find.byType(ImageBubble)), expected);
      await _expectEdges(tester, key);
    });
  }

  testWidgets('AC:RL-single-image-uncropped/4 sticker_fallback', (
    tester,
  ) async {
    final event = _ImageEvent(
      room: room,
      bytes: fixtures[(576, 1280)]!,
      info: null,
      sticker: true,
    );
    final key = await _pump(tester, event);
    expect(tester.getSize(find.byType(ImageBubble)), const Size(128, 128));
    await _expectEdges(tester, key);
  });

  testWidgets('AC:RL-single-image-uncropped/5 separate_thumbnail', (
    tester,
  ) async {
    final event = _ImageEvent(
      room: room,
      bytes: fixtures[(512, 512)]!,
      thumbnailBytes: fixtures[(576, 1280)]!,
      info: {'thumbnail_url': 'mxc://example.invalid/thumbnail'},
    );
    final key = await _pump(tester, event);
    await _expectEdges(tester, key);
    expect(event.thumbnailRequests, [true]);
    expect(
      (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes,
      same(event.thumbnailBytes),
    );
  });

  testWidgets('положительные размеры не совпадают с байтами', (tester) async {
    final event = _ImageEvent(
      room: room,
      bytes: fixtures[(576, 1280)]!,
      info: {'w': 1280, 'h': 576},
    );
    final key = await _pump(tester, event);
    await _expectEdges(tester, key);
  });

  testWidgets('placeholder и загруженное изображение сохраняют геометрию', (
    tester,
  ) async {
    final gate = Completer<void>();
    final event = _ImageEvent(
      room: room,
      bytes: fixtures[(576, 1280)]!,
      info: null,
      loadGate: gate,
    );
    final key = await _pump(tester, event);
    final before = tester.getRect(find.byType(ImageBubble));
    expect(find.byType(BlurHash), findsOneWidget);
    gate.complete();
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.getRect(find.byType(ImageBubble)), before);
    await _expectEdges(tester, key);
  });
}
