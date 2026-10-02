// Страж LABA-2621: за одну отправку — не больше `maxAttachmentsPerSend` файлов,
// медиа-набор режется на альбомы по `albumChunkSize` (как в Telegram), а
// заголовок диалога склоняется по-русски.
//
// Диалог — РЕАЛЬНЫЙ `SendFileDialog` в реальном `MaterialApp`, превью — реально
// декодируемые PNG. Нарезка — чистая `buildAlbumExtra`, которую зовут ОБА сайта
// `_send` (пре-эмит и финал); это закреплено структурным ассертом по исходнику.
//
// ledger:RL-send-dialog-attach-limit

library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/send_file_dialog.dart';

import '../../utils/test_client.dart';

const _roomId = '!attachlimit:example.invalid';
const _tileKey = Key('add-more-tile');
const _noteKey = Key('attach-limit-note');
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

XFile _pdf(String name) => XFile.fromData(
  Uint8List.fromList(List<int>.filled(64, 7)),
  mimeType: 'application/pdf',
  path: name,
  name: name,
);

List<XFile> _imgs(int n, [String prefix = 'p']) => [
  for (var i = 0; i < n; i++) _img('$prefix$i.png'),
];

/// Пикер «+» (LABA-2619), отдающий [count] изображений за один выбор.
Future<List<XFile>> Function(BuildContext, int) _picker(int count) =>
    (_, _) async => _imgs(count, 'new');

Future<void> _openDialog(
  WidgetTester tester,
  Room room,
  List<XFile> files, {
  int picked = 1,
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
  // Делегаты L10n грузятся отложенно (deferred), en — только реальным
  // временем через runAsync; pumpAndSettle нельзя — живой Client.
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
      moreImagesPicker: _picker(picked),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

SendFileDialog _dialog(WidgetTester tester) =>
    tester.widget<SendFileDialog>(find.byType(SendFileDialog));

String? _noteText(WidgetTester tester) {
  final note = find.byKey(_noteKey);
  if (note.evaluate().isEmpty) return null;
  return tester
      .widget<Text>(find.descendant(of: note, matching: find.byType(Text)))
      .data;
}

InkWell _tileInk(WidgetTester tester) => tester.widget<InkWell>(
  find.descendant(of: find.byKey(_tileKey), matching: find.byType(InkWell)),
);

/// Лента у конца — плитка «+» построена (ListView ленивый).
Future<void> _scrollRibbonToEnd(WidgetTester tester) async {
  final ribbon = find.byType(ListView).last;
  for (var step = 0; step < 60; step++) {
    if (find.byKey(_tileKey).evaluate().isNotEmpty) return;
    await tester.drag(ribbon, const Offset(-400, 0));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Client client;
  late Room room;

  late L10n en;

  setUpAll(() async {
    // До инициализации binding: после неё deferred-загрузка en виснет.
    en = await lookupL10n(const Locale('en'));
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

  group('кап набора в диалоге', () {
    testWidgets('AC:RL-send-dialog-attach-limit/1 — 42 изображения → в '
        'диалоге ровно $_limit, первые по порядку', (tester) async {
      await _openDialog(tester, room, _imgs(42));
      final d = _dialog(tester);
      expect(d.files.length, _limit);
      expect(d.overflowCount, 12);
      expect(d.files.map((f) => f.name).toList(), [
        for (var i = 0; i < _limit; i++) 'p$i.png',
      ]);
      expect(find.text('Отправить 30 изображений'), findsOneWidget);
    });

    testWidgets('AC:RL-send-dialog-attach-limit/2 — 42: строка лимита и '
        '«лишние 12»', (tester) async {
      await _openDialog(tester, room, _imgs(42));
      expect(
        _noteText(tester),
        'За раз можно отправить не больше 30 файлов. '
        'Лишние 12 файлов не добавлены.',
      );
    });

    testWidgets('AC:RL-send-dialog-attach-limit/2 — ровно 30: строка лимита '
        'без «лишних»', (tester) async {
      await _openDialog(tester, room, _imgs(_limit));
      expect(_noteText(tester), 'За раз можно отправить не больше 30 файлов.');
    });

    testWidgets('AC:RL-send-dialog-attach-limit/2 — 29: строки нет', (
      tester,
    ) async {
      await _openDialog(tester, room, _imgs(_limit - 1));
      expect(find.byKey(_noteKey), findsNothing);
    });

    test('AC:RL-send-dialog-attach-limit/2 — en-строки', () {
      expect(en.attachLimitReached(30), 'You can send up to 30 files at once.');
      expect(en.attachLimitDropped(1), '1 extra file was not added.');
      expect(en.attachLimitDropped(12), '12 extra files were not added.');
    });

    testWidgets('AC:RL-send-dialog-attach-limit/3 — на лимите плитка «+» '
        'гаснет, но остаётся в ленте', (tester) async {
      await _openDialog(tester, room, _imgs(_limit));
      await _scrollRibbonToEnd(tester);
      expect(find.byKey(_tileKey), findsOneWidget);
      expect(_tileInk(tester).onTap, isNull);
    });

    testWidgets('AC:RL-send-dialog-attach-limit/3 — ниже лимита «+» '
        'активна', (tester) async {
      await _openDialog(tester, room, _imgs(_limit - 1));
      await _scrollRibbonToEnd(tester);
      expect(_tileInk(tester).onTap, isNotNull);
    });

    testWidgets('AC:RL-send-dialog-attach-limit/4 — 28 + «+» выбрал 5 → 30: '
        'старые на месте, «лишние 3»', (tester) async {
      await _openDialog(tester, room, _imgs(28), picked: 5);
      await _scrollRibbonToEnd(tester);
      await tester.tap(find.byKey(_tileKey));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byType(SendFileDialog),
        findsOneWidget,
        reason: 'старый диалог закрыт, новый открыт',
      );

      final d = _dialog(tester);
      expect(d.files.length, _limit);
      expect(d.files.take(28).map((f) => f.name).toList(), [
        for (var i = 0; i < 28; i++) 'p$i.png',
      ]);
      expect(d.overflowCount, 3);
      expect(_noteText(tester), contains('Лишние 3 файла не добавлены.'));
    });

    testWidgets('AC:RL-send-dialog-attach-limit/5 — кап и для документов', (
      tester,
    ) async {
      await _openDialog(tester, room, [
        for (var i = 0; i < 42; i++) _pdf('d$i.pdf'),
      ]);
      expect(_dialog(tester).files.length, _limit);
      expect(_noteText(tester), contains('Лишние 12 файлов'));
    });
  });

  group('склонение заголовка', () {
    const ru = {
      2: 'Отправить 2 изображения',
      5: 'Отправить 5 изображений',
      21: 'Отправить 21 изображение',
      22: 'Отправить 22 изображения',
      30: 'Отправить 30 изображений',
    };
    for (final e in ru.entries) {
      testWidgets('AC:RL-send-dialog-attach-limit/9 — ru ${e.key}', (
        tester,
      ) async {
        await _openDialog(tester, room, _imgs(e.key));
        expect(find.text(e.value), findsOneWidget);
      });
    }
    test('AC:RL-send-dialog-attach-limit/9 — en', () {
      expect(en.sendImages(1), 'Send 1 image');
      expect(en.sendImages(2), 'Send 2 images');
    });
  });

  group('нарезка на альбомы', () {
    List<Map<String, dynamic>?> slots(int total, {String caption = ''}) {
      final ids = [for (var k = 0; k < albumCountFor(total); k++) 'g$k'];
      return [
        for (var i = 0; i < total; i++)
          buildAlbumExtra(
            albumIds: ids,
            index: i,
            total: total,
            caption: caption,
          ),
      ];
    }

    Map<String, dynamic>? g(Map<String, dynamic>? e) =>
        e?['com.liza.gallery'] as Map<String, dynamic>?;

    test('AC:RL-send-dialog-attach-limit/6 — 30 → три альбома по 10, '
        'локальные i 0..9', () {
      final s = slots(30);
      for (var i = 0; i < 30; i++) {
        expect(g(s[i])!['id'], 'g${i ~/ 10}');
        expect(g(s[i])!['i'], i % 10);
        expect(g(s[i])!['n'], 10);
      }
    });

    test('AC:RL-send-dialog-attach-limit/6 — хвост: 11 → 10 + одиночный, '
        '21 → 10+10+1, 12 → 10+2', () {
      final s11 = slots(11);
      expect(g(s11[9])!['n'], 10);
      expect(s11[10], isNull, reason: 'хвост-одиночка без gallery');

      final s21 = slots(21);
      expect(g(s21[19])!['id'], 'g1');
      expect(s21[20], isNull);

      final s12 = slots(12);
      expect(g(s12[10]), {'id': 'g1', 'i': 0, 'n': 2});
      expect(g(s12[11]), {'id': 'g1', 'i': 1, 'n': 2});
    });

    test(
      'AC:RL-send-dialog-attach-limit/6 — до 10 — один альбом как раньше',
      () {
        final s = slots(7);
        expect(s.map((e) => g(e)!['id']).toSet(), {'g0'});
        expect(s.map((e) => g(e)!['n']).toSet(), {7});
      },
    );

    test('AC:RL-send-dialog-attach-limit/7 — подпись только на первом файле '
        'всего набора', () {
      final s = slots(21, caption: 'Осень');
      expect(s[0]!['body'], 'Осень');
      expect(g(s[0])!['caption'], 'Осень');
      for (var i = 1; i < 21; i++) {
        expect(s[i]?['body'], isNull, reason: 'файл $i');
        expect(g(s[i])?['caption'], isNull, reason: 'файл $i');
      }
    });

    test('AC:RL-send-dialog-attach-limit/7 — не альбомный набор: подпись '
        'одиночного файла по-прежнему в body', () {
      expect(
        buildAlbumExtra(albumIds: null, index: 0, total: 1, caption: 'x'),
        {'body': 'x'},
      );
    });

    test('AC:RL-send-dialog-attach-limit/8 — пре-эмит и финал `_send` берут '
        'id/i/n из одной `buildAlbumExtra`', () {
      final src = File(
        'lib/pages/chat/send_file_dialog.dart',
      ).readAsStringSync();
      final body = src.substring(src.indexOf('Future<void> _send()'));
      expect(
        'buildAlbumExtra('.allMatches(body).length,
        2,
        reason: 'оба сайта — через нарезку',
      );
      expect(
        'buildGalleryExtra('.allMatches(body).length,
        0,
        reason: 'прямой вызов мимо нарезки развёл бы n пре-эмита и финала',
      );
    });
  });
}
