// Страж LABA-2631: после «+» (добор изображений, LABA-2619) диалог пересоздаётся, и его лента
// превью обязана открыться у КОНЦА — видны только что вставленное и плитка «+»,
// следующую вставку можно сделать без листания.
//
// Гоняется РЕАЛЬНЫЙ `SendFileDialog` в реальном `MaterialApp`/`Navigator`, с
// РЕАЛЬНО декодируемыми PNG: без декодирования превью имеют нулевую ширину,
// лента не переполняется и страж зеленел бы на любом коде.
//
// ledger:RL-send-dialog-add-more-scroll-end

library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/send_file_dialog.dart';

import '../../utils/test_client.dart';

const _roomId = '!addmorescroll:example.invalid';
const _tileKey = Key('add-more-tile');

/// Узкий портрет 40×100: при высоте превью 256 каждое ≈102 dp — пять штук
/// гарантированно переполняют ленту шириной 256, а последнее превью вместе с
/// плиткой «+» (104 dp) в неё помещается.
late Uint8List _png;

Future<Uint8List> _makePng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

XFile _img(String name) =>
    XFile.fromData(_png, mimeType: 'image/png', path: name, name: name);

/// Файл, чьи байты отдаются только по команде теста — моделирует догрузку
/// превью после первого кадра (спиннер → картинка, ширина растёт).
class _DelayedXFile extends XFile {
  _DelayedXFile(String name, this.gate)
    : super.fromData(_png, mimeType: 'image/png', path: name, name: name);

  final Completer<void> gate;

  @override
  Future<Uint8List> readAsBytes() async {
    await gate.future;
    return _png;
  }
}

/// Пикер «+» (LABA-2619): каждый вызов отдаёт одно изображение — как выбор
/// одного файла в проводнике/галерее.
var _picked = 0;
Future<List<XFile>> _fakePicker(BuildContext _, int _) async => [
  _img('picked${_picked++}.png'),
];

Future<void> _decode(WidgetTester tester) async {
  for (var k = 0; k < 3; k++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}

/// Та же ловушка, что в `send_dialog_two_actions_test`: делегаты `L10n`
/// грузятся отложенно — нужны два `pump(500ms)`; `pumpAndSettle` запрещён
/// (живой `Client` крутит таймеры, в ленте крутятся спиннеры).
Future<void> _openDialog(
  WidgetTester tester,
  Room room,
  List<XFile> files, {
  required TargetPlatform platform,
  bool scrollToEndOnOpen = false,
}) async {
  BuildContext? outer;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            outer = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));

  showDialog<void>(
    context: outer!,
    builder: (_) => SendFileDialog(
      room: room,
      files: files,
      outerContext: outer!,
      threadLastEventId: null,
      threadRootEventId: null,
      scrollToEndOnOpen: scrollToEndOnOpen,
      moreImagesPicker: _fakePicker,
    ),
  );
  await tester.pump();
}

Finder get _ribbon => find.byType(ListView);

Finder _preview(int index) =>
    find.byWidgetPredicate((w) => w is IndexedSemantics && w.index == index);

bool _inside(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.5 && inner.right <= outer.right + 0.5;

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _ribbon, matching: find.byType(Scrollable)),
    )
    .position;

void main() {
  late Client client;
  late Room room;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _png = await _makePng(40, 100);
  });

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: _roomId, client: client);
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  void setScreen(WidgetTester tester) {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 640) * 2.0;
    addTearDown(tester.view.reset);
  }

  List<XFile> five() => [for (var i = 0; i < 5; i++) _img('p$i.png')];

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    group(platform.name, () {
      testWidgets('AC:RL-send-dialog-add-more-scroll-end/1 — плитка «+» видна '
          'на первом кадре', (tester) async {
        setScreen(tester);
        await _openDialog(
          tester,
          room,
          five(),
          platform: platform,
          scrollToEndOnOpen: true,
        );
        expect(
          _inside(
            tester.getRect(find.byKey(_tileKey)),
            tester.getRect(_ribbon),
          ),
          isTrue,
          reason: 'без мигания с offset 0: плитка у правого края сразу',
        );
        await _decode(tester);
        expect(
          _inside(
            tester.getRect(find.byKey(_tileKey)),
            tester.getRect(_ribbon),
          ),
          isTrue,
          reason: 'и после декодирования превью',
        );
      });

      testWidgets('AC:RL-send-dialog-add-more-scroll-end/2 — последнее превью '
          'видно целиком и стоит левее плитки', (tester) async {
        setScreen(tester);
        await _openDialog(
          tester,
          room,
          five(),
          platform: platform,
          scrollToEndOnOpen: true,
        );
        await _decode(tester);
        final last = tester.getRect(_preview(4));
        final tile = tester.getRect(find.byKey(_tileKey));
        expect(last.width, greaterThan(100), reason: 'превью декодировано');
        expect(_inside(last, tester.getRect(_ribbon)), isTrue);
        expect(last.right, lessThanOrEqualTo(tile.left + 0.5));
      });

      testWidgets('AC:RL-send-dialog-add-more-scroll-end/3 — без флага лента '
          'открывается в начале', (tester) async {
        setScreen(tester);
        await _openDialog(tester, room, five(), platform: platform);
        await _decode(tester);
        expect(_position(tester).pixels, 0);
        expect(
          tester.getRect(_preview(0)).left,
          moreOrLessEquals(tester.getRect(_ribbon).left, epsilon: 0.5),
        );
        final tile = find.byKey(_tileKey);
        expect(
          tile.evaluate().isEmpty ||
              !_inside(tester.getRect(tile), tester.getRect(_ribbon)),
          isTrue,
          reason: 'контроль: переполненная лента без флага — плитка за краем',
        );
      });

      testWidgets('AC:RL-send-dialog-add-more-scroll-end/4 — догрузка превью '
          'не сдвигает плитку', (tester) async {
        setScreen(tester);
        final gate = Completer<void>();
        await _openDialog(
          tester,
          room,
          [for (var i = 0; i < 5; i++) _DelayedXFile('d$i.png', gate)],
          platform: platform,
          scrollToEndOnOpen: true,
        );
        await tester.pump(const Duration(milliseconds: 300));
        final before = tester.getRect(find.byKey(_tileKey));
        final widthBefore = tester.getRect(_preview(4)).width;

        gate.complete();
        await _decode(tester);

        expect(
          tester.getRect(_preview(4)).width,
          greaterThan(widthBefore + 50),
          reason: 'ширины реально выросли — иначе проверка пустая',
        );
        final after = tester.getRect(find.byKey(_tileKey));
        expect(after.left, moreOrLessEquals(before.left, epsilon: 0.5));
        expect(_inside(after, tester.getRect(_ribbon)), isTrue);
      });

      testWidgets('AC:RL-send-dialog-add-more-scroll-end/5 — «+» три раза '
          'подряд без листания', (tester) async {
        setScreen(tester);
        await _openDialog(tester, room, five(), platform: platform);
        await tester.pump(const Duration(milliseconds: 500));
        await _decode(tester);

        // Сценарий тикета: пролистать до плитки вручную.
        // Шагами, с декодированием: превью за краем строятся лениво, и их
        // ширины (а с ними maxScrollExtent) известны только после декода.
        for (var step = 0; step < 12; step++) {
          final tile = find.byKey(_tileKey);
          if (tile.evaluate().isNotEmpty &&
              _inside(tester.getRect(tile), tester.getRect(_ribbon))) {
            break;
          }
          await tester.drag(_ribbon, const Offset(-150, 0));
          await tester.pump(const Duration(milliseconds: 500));
          await _decode(tester);
        }

        for (var round = 1; round <= 3; round++) {
          final tile = find.byKey(_tileKey);
          expect(
            _inside(tester.getRect(tile), tester.getRect(_ribbon)),
            isTrue,
            reason: 'раунд $round: плитка видна без листания',
          );
          await tester.tap(tile);
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          final dialog = tester.widget<SendFileDialog>(
            find.byType(SendFileDialog),
          );
          expect(dialog.files.length, 5 + round);
          expect(dialog.scrollToEndOnOpen, isTrue);
          await _decode(tester);
          expect(
            _inside(
              tester.getRect(_preview(4 + round)),
              tester.getRect(_ribbon),
            ),
            isTrue,
            reason: 'раунд $round: вставленное видно',
          );
        }
      });

      testWidgets('AC:RL-send-dialog-add-more-scroll-end/6 — порядок превью '
          'слева направо = порядок набора', (tester) async {
        setScreen(tester);
        await _openDialog(
          tester,
          room,
          five(),
          platform: platform,
          scrollToEndOnOpen: true,
        );
        await _decode(tester);
        final built = tester
            .widgetList<IndexedSemantics>(
              find.descendant(
                of: _ribbon,
                matching: find.byType(IndexedSemantics),
              ),
            )
            .toList();
        expect(built.length, greaterThanOrEqualTo(2));
        final byX = [...built]
          ..sort(
            (a, b) => tester
                .getRect(find.byWidget(a))
                .left
                .compareTo(tester.getRect(find.byWidget(b)).left),
          );
        final indexes = byX.map((w) => w.index).toList();
        expect(indexes, [...indexes]..sort());
        expect(indexes.last, 5, reason: 'плитка «+» — последняя');
      });
    });
  }
}
