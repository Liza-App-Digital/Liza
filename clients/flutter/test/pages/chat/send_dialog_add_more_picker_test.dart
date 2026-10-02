// Страж LABA-2619: плитка «+» в диалоге отправки открывает ВЫБОР ИЗОБРАЖЕНИЙ
// (проводник/Finder, на mobile — галерею) и добирает выбранное к набору, а не
// читает буфер обмена. Накопление из буфера (RL-paste-accumulate-album) живёт
// на Cmd/Ctrl+V внутри открытого диалога.
//
// Гоняется РЕАЛЬНЫЙ `SendFileDialog` в реальном `MaterialApp`/`Navigator`;
// пикер и буфер — инжектируемые фейки, считающие свои вызовы.
//
// ledger:RL-send-dialog-add-more-picker

library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/send_file_dialog.dart';
import 'package:liza/utils/clipboard_paste.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';

import '../../utils/test_client.dart';

const _roomId = '!addmorepicker:example.invalid';
const _tileKey = Key('add-more-tile');
const _limit = AppConfig.maxAttachmentsPerSend;

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

XFile _file(String name, String mime) => XFile.fromData(
  Uint8List.fromList(List<int>.filled(64, 7)),
  mimeType: mime,
  path: name,
  name: name,
);

List<XFile> _imgs(int n, [String prefix = 'p']) => [
  for (var i = 0; i < n; i++) _img('$prefix$i.png'),
];

/// Пикер, отдающий заранее заданный ответ и запоминающий каждый `limit`.
class _FakePicker {
  _FakePicker(this.answer);

  final List<XFile> answer;
  final limits = <int>[];

  Future<List<XFile>> call(BuildContext _, int limit) async {
    limits.add(limit);
    return answer;
  }
}

/// Буфер: [text] — текст, [image] — один растр; считает обращения.
class _FakeReader implements PasteboardReader {
  _FakeReader({this.clipText, this.clipImage});

  final String? clipText;
  final Uint8List? clipImage;
  int reads = 0;

  @override
  Future<String?> text() async {
    reads++;
    return clipText;
  }

  @override
  Future<List<XFile>> files() async => [];
  @override
  Future<List<Uint8List>> images() async => [];
  @override
  Future<Uint8List?> image() async => clipImage;
}

Future<void> _openDialog(
  WidgetTester tester,
  Room room,
  List<XFile> files, {
  required _FakePicker picker,
  _FakeReader? reader,
  bool compress = true,
  String? caption,
}) async {
  BuildContext? outer;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
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
  // Делегаты L10n грузятся отложенно — нужно реальное время (runAsync);
  // pumpAndSettle нельзя — живой Client крутит таймеры.
  for (var k = 0; k < 3; k++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  showDialog<void>(
    context: outer!,
    builder: (_) => SendFileDialog(
      room: room,
      files: files,
      outerContext: outer!,
      threadLastEventId: null,
      threadRootEventId: null,
      compress: compress,
      initialCaption: caption,
      moreImagesPicker: picker.call,
      pasteboardReader: reader ?? _FakeReader(clipImage: _png),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

SendFileDialog _dialog(WidgetTester tester) =>
    tester.widget<SendFileDialog>(find.byType(SendFileDialog));

InkWell _tileInk(WidgetTester tester) => tester.widget<InkWell>(
  find.descendant(of: find.byKey(_tileKey), matching: find.byType(InkWell)),
);

/// Лента у плитки: на 2+ файлах плитка может быть за краем ленты.
Future<void> _scrollRibbonToEnd(WidgetTester tester) async {
  final ribbon = find.byType(ListView);
  for (var i = 0; i < 40 && find.byKey(_tileKey).evaluate().isEmpty; i++) {
    await tester.drag(ribbon, const Offset(-300, 0));
    await tester.pump();
  }
}

Future<void> _tapTile(WidgetTester tester) async {
  await _scrollRibbonToEnd(tester);
  _tileInk(tester).onTap!();
  await _settle(tester);
}

/// Текст подписи: на iOS/macOS адаптивный диалог рисует `CupertinoTextField`,
/// поэтому ищем общий для обоих `EditableText`.
String _caption(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).controller.text;

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _pressPaste(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await _settle(tester);
}

void main() {
  late Client client;
  late Room room;
  late L10n ru;
  late L10n en;

  setUpAll(() async {
    // До инициализации binding: после неё deferred-загрузка en виснет.
    ru = await lookupL10n(const Locale('ru'));
    en = await lookupL10n(const Locale('en'));
    TestWidgetsFlutterBinding.ensureInitialized();
    _png = await _makePng(40, 100);
  });

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: _roomId, client: client);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  group('«+» открывает выбор изображений', () {
    testWidgets('AC:RL-send-dialog-add-more-picker/1 — тап «+» зовёт пикер '
        'ровно раз и не читает буфер', (tester) async {
      final picker = _FakePicker([_img('new.png')]);
      final reader = _FakeReader(clipImage: _png);
      await _openDialog(tester, room, _imgs(2), picker: picker, reader: reader);
      await _tapTile(tester);
      expect(picker.limits.length, 1);
      expect(reader.reads, 0, reason: '«+» больше не читает буфер');
    });

    testWidgets('AC:RL-send-dialog-add-more-picker/2 — K выбранных добавлены '
        'в конец набора, лента у правого края', (tester) async {
      final picker = _FakePicker(_imgs(3, 'new'));
      await _openDialog(tester, room, _imgs(2), picker: picker);
      await _tapTile(tester);
      final d = _dialog(tester);
      expect(d.files.map((f) => f.name).toList(), [
        'p0.png',
        'p1.png',
        'new0.png',
        'new1.png',
        'new2.png',
      ]);
      expect(d.scrollToEndOnOpen, isTrue);
      expect(find.byKey(_tileKey), findsOneWidget);
    });

    final noImages = <String, List<XFile>>{
      'отмена/пусто': [],
      'только видео': [_file('clip.mp4', 'video/mp4')],
      'только pdf': [_file('doc.pdf', 'application/pdf')],
    };
    for (final e in noImages.entries) {
      testWidgets('AC:RL-send-dialog-add-more-picker/3 — ${e.key}: набор '
          'прежний, без SnackBar, «+» снова активна', (tester) async {
        final picker = _FakePicker(e.value);
        await _openDialog(tester, room, _imgs(2), picker: picker);
        await _tapTile(tester);
        expect(_dialog(tester).files.length, 2);
        expect(find.byType(SnackBar), findsNothing);
        expect(
          _tileInk(tester).onTap,
          isNotNull,
          reason: '_addingMore сброшен — иначе залипли бы и «+», и «Прислать»',
        );
      });
    }

    testWidgets('AC:RL-send-dialog-add-more-picker/4 — смешанный ответ: '
        'добавлены только изображения, плитка на месте', (tester) async {
      final picker = _FakePicker([
        _img('a.png'),
        _file('clip.mp4', 'video/mp4'),
        _file('doc.pdf', 'application/pdf'),
      ]);
      await _openDialog(tester, room, _imgs(1), picker: picker);
      await _tapTile(tester);
      expect(_dialog(tester).files.map((f) => f.name).toList(), [
        'p0.png',
        'a.png',
      ]);
      await _scrollRibbonToEnd(tester);
      expect(find.byKey(_tileKey), findsOneWidget);
    });

    for (final caption in ['', 'строка 1\nстрока 2', 'фото 🌲🍂']) {
      testWidgets('AC:RL-send-dialog-add-more-picker/5 — подпись «$caption» '
          'переживает «+»', (tester) async {
        final picker = _FakePicker([_img('new.png')]);
        await _openDialog(
          tester,
          room,
          _imgs(1),
          picker: picker,
          caption: caption,
        );
        await _tapTile(tester);
        expect(_dialog(tester).initialCaption, caption);
        expect(find.byType(EditableText), findsOneWidget);
        expect(_caption(tester), caption);
      });
    }

    for (final n in [1, 28, 29]) {
      testWidgets('AC:RL-send-dialog-add-more-picker/6 — набор $n → лимит '
          'пикера ${_limit - n}', (tester) async {
        final picker = _FakePicker([]);
        await _openDialog(tester, room, _imgs(n), picker: picker);
        await _tapTile(tester);
        expect(picker.limits, [_limit - n]);
      });
    }

    testWidgets('AC:RL-send-dialog-add-more-picker/7 — 28 + выбрано 5 → 30 и '
        '«Лишние 3»', (tester) async {
      final picker = _FakePicker(_imgs(5, 'new'));
      await _openDialog(tester, room, _imgs(28), picker: picker);
      await _tapTile(tester);
      final d = _dialog(tester);
      expect(d.files.length, _limit);
      expect(d.overflowCount, 3);
    });

    testWidgets(
      'AC:RL-send-dialog-add-more-picker/8 — на лимите «+» неактивна, '
      'пикер не зовётся',
      (tester) async {
        final picker = _FakePicker([_img('new.png')]);
        await _openDialog(tester, room, _imgs(_limit), picker: picker);
        await _scrollRibbonToEnd(tester);
        expect(_tileInk(tester).onTap, isNull);
        expect(picker.limits, isEmpty);
      },
    );

    for (final compress in [true, false]) {
      testWidgets('AC:RL-send-dialog-add-more-picker/12 — compress=$compress '
          'сохраняется после «+»', (tester) async {
        final picker = _FakePicker([_img('new.png')]);
        await _openDialog(
          tester,
          room,
          _imgs(1),
          picker: picker,
          compress: compress,
        );
        await _tapTile(tester);
        expect(_dialog(tester).compress, compress);
        expect(_dialog(tester).files.length, 2);
      });
    }

    testWidgets('AC:RL-send-dialog-add-more-picker/12 — пересозданный диалог '
        'сохраняет тот же пикер (второй «+» идёт в него же)', (tester) async {
      final picker = _FakePicker([_img('new.png')]);
      await _openDialog(tester, room, _imgs(1), picker: picker);
      await _tapTile(tester);
      await _tapTile(tester);
      expect(picker.limits, [_limit - 1, _limit - 2]);
      expect(_dialog(tester).files.length, 3);
    });
  });

  group('Cmd/Ctrl+V в открытом диалоге', () {
    testWidgets('AC:RL-send-dialog-add-more-picker/10 — изображение в буфере, '
        'фокус вне поля → +1 в наборе', (tester) async {
      final picker = _FakePicker([]);
      await _openDialog(tester, room, _imgs(2), picker: picker);
      await _pressPaste(tester);
      expect(_dialog(tester).files.length, 3);
      expect(picker.limits, isEmpty, reason: 'вставка не открывает пикер');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('AC:RL-send-dialog-add-more-picker/10 — изображение в буфере, '
        'фокус в подписи → +1 в наборе, подпись не тронута', (tester) async {
      await _openDialog(
        tester,
        room,
        _imgs(2),
        picker: _FakePicker([]),
        caption: 'подпись',
      );
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await _pressPaste(tester);
      expect(_dialog(tester).files.length, 3);
      expect(_caption(tester), 'подпись');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('AC:RL-send-dialog-add-more-picker/11 — текст в буфере, фокус '
        'в подписи → текст вставлен, набор прежний', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => switch (call.method) {
          'Clipboard.getData' => {'text': 'привет'},
          'Clipboard.hasStrings' => {'value': true},
          _ => null,
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _openDialog(
        tester,
        room,
        _imgs(2),
        picker: _FakePicker([]),
        reader: _FakeReader(clipText: 'привет'),
      );
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await _pressPaste(tester);
      expect(_dialog(tester).files.length, 2);
      expect(_caption(tester), 'привет');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('AC:RL-send-dialog-add-more-picker/9 — во время отправки '
        'Cmd+V не читает буфер', (tester) async {
      final reader = _FakeReader(clipImage: _png);
      await _openDialog(
        tester,
        room,
        _imgs(1),
        picker: _FakePicker([]),
        reader: reader,
      );
      final send = tester.widget<AdaptiveDialogAction>(
        find.ancestor(
          of: find.text(ru.send),
          matching: find.byType(AdaptiveDialogAction),
        ),
      );
      send.onPressed!();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pump();
      expect(reader.reads, 0);

      // Дать `_send` дойти до `finally` и снять плашку (её SnackBar живёт
      // минуты) — иначе «A Timer is still pending» уже после ассерта.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  test('AC:RL-send-dialog-add-more-picker/13 — «Добавить ещё» / «Add more», '
      'ключа pasteMore нет', () {
    expect(ru.addMoreImages, 'Добавить ещё');
    expect(en.addMoreImages, 'Add more');
    for (final arb in Directory('lib/l10n').listSync().whereType<File>()) {
      if (!arb.path.endsWith('.arb')) continue;
      expect(
        arb.readAsStringSync().contains('"pasteMore"'),
        isFalse,
        reason: arb.path,
      );
    }
  });
}
