// Страж заявки №52: подпись к вложению не режется молча. До 1024 графем —
// подпись (`body` первого файла), длиннее — файлы без подписи и следом ровно
// одно текстовое сообщение (как в Telegram). Не ушёл ни один файл — текст
// возвращается в композер, а не уходит один.
//
// Диалог — РЕАЛЬНЫЙ `SendFileDialog` в реальном `MaterialApp`; комната —
// `Room` с перехваченными `sendFileEvent`/`sendTextEvent` (сеть не нужна,
// проверяем, ЧТО и в каком порядке `_send` отдаёт SDK).
//
// ledger:RL-send-caption-limit

library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/message_content.dart';
import 'package:liza/pages/chat/send_file_dialog.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';

import '../../utils/test_client.dart';

const _noteKey = Key('caption-limit-note');

/// Что `_send` отдал SDK, по порядку: `file:<body|->` и `text:<длина>`.
class _SpyRoom extends Room {
  _SpyRoom({required super.id, required super.client});

  final List<String> log = [];
  final List<Map<String, dynamic>?> fileExtras = [];
  final List<String> texts = [];
  final List<String?> textThreads = [];
  bool failFiles = false;

  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    if (failFiles) {
      throw MatrixException.fromJson({
        'errcode': 'M_FORBIDDEN',
        'error': 'nope',
      });
    }
    fileExtras.add(extraContent);
    log.add('file:${extraContent?['body'] == null ? '-' : 'caption'}');
    return '\$file${fileExtras.length}';
  }

  @override
  Future<String?> sendTextEvent(
    String message, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    bool parseMarkdown = true,
    bool parseCommands = true,
    String msgtype = MessageTypes.Text,
    String? threadRootEventId,
    String? threadLastEventId,
    StringBuffer? commandStdout,
    bool addMentions = true,
    bool displayPendingEvent = true,
  }) async {
    texts.add(message);
    textThreads.add(threadRootEventId);
    log.add('text:${message.length}');
    return '\$text${texts.length}';
  }
}

XFile _doc(String name) => XFile.fromData(
  Uint8List.fromList(List<int>.filled(64, 7)),
  mimeType: 'application/pdf',
  path: name,
  name: name,
);

String _chars(int n) => List.filled(n, 'а').join();

Future<BuildContext> _pumpHost(WidgetTester tester) async {
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
  // Делегаты L10n грузятся отложенно — см. send_file_dialog_feedback_test.
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  return outer!;
}

Future<void> _openDialog(
  WidgetTester tester,
  Room room,
  List<XFile> files, {
  String? caption,
  ValueChanged<String>? onUnsentText,
  String? threadRootEventId,
}) async {
  final outer = await _pumpHost(tester);
  showDialog<void>(
    context: outer,
    builder: (_) => SendFileDialog(
      room: room,
      files: files,
      outerContext: outer,
      threadLastEventId: threadRootEventId,
      threadRootEventId: threadRootEventId,
      compress: false,
      initialCaption: caption,
      onUnsentText: onUnsentText,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

TextEditingController _captionController(WidgetTester tester) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byType(SendFileDialog),
        matching: find.byType(TextField),
      ),
    )
    .controller!;

/// Тап «Отправить» реальным обработчиком и прогон `_send` до конца.
Future<void> _send(WidgetTester tester) async {
  final l10n = await tester.runAsync(
    () => L10n.delegate.load(const Locale('ru')),
  );
  tester
      .widget<AdaptiveDialogAction>(
        find.ancestor(
          of: find.text(l10n!.send),
          matching: find.byType(AdaptiveDialogAction),
        ),
      )
      .onPressed!();
  for (var k = 0; k < 6; k++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// `client.getConfig()` кэшируется SDK на час (`AsyncCache`), плашка
/// подготовки — `SnackBar` на 5 минут: снимаем дерево и прокручиваем часы,
/// иначе тест падает на «Timer is still pending».
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(hours: 2));
}

void main() {
  late Client client;
  late _SpyRoom room;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    room = _SpyRoom(id: '!caption52:example.invalid', client: client);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  group('AC:RL-send-caption-limit/1 — лимит константой, без maxLength', () {
    test('AppConfig.maxCaptionLength == 1024', () {
      expect(AppConfig.maxCaptionLength, 1024);
    });

    test('поле подписи не режет ввод maxLength-ом', () {
      final code = File(
        'lib/pages/chat/send_file_dialog.dart',
      ).readAsStringSync();
      expect(code.contains('maxLength: 255'), isFalse);
    });
  });

  group('splitCaption — граница и графемы', () {
    test('ровно 1024 — подпись, 1025 — отдельным текстом', () {
      expect(splitCaption(_chars(1024)), (
        caption: _chars(1024),
        trailingText: null,
      ));
      expect(splitCaption(_chars(1025)), (
        caption: '',
        trailingText: _chars(1025),
      ));
    });

    test('эмодзи-семья — одна графема, а не 11 code units', () {
      const family = '👨‍👩‍👧‍👦';
      final text = List.filled(1024, family).join();
      expect(text.length, greaterThan(1024));
      expect(splitCaption(text).trailingText, isNull);
    });
  });

  testWidgets('AC:RL-send-caption-limit/2 — вставка 1500 символов не режется', (
    tester,
  ) async {
    await _openDialog(tester, room, [_doc('a.pdf')]);
    await tester.enterText(
      find.descendant(
        of: find.byType(SendFileDialog),
        matching: find.byType(TextField),
      ),
      _chars(1500),
    );
    await tester.pump();
    expect(_captionController(tester).text.length, 1500);
  });

  testWidgets(
    'AC:RL-send-caption-limit/4 AC:RL-send-caption-limit/9 — счётчик с 900, предупреждение после 1024',
    (tester) async {
      await _openDialog(tester, room, [_doc('a.pdf')]);
      final controller = _captionController(tester);
      final ru = (await tester.runAsync(
        () => L10n.delegate.load(const Locale('ru')),
      ))!;
      final warning = ru.captionSentSeparately(AppConfig.maxCaptionLength);

      String? note() {
        final f = find.byKey(_noteKey);
        if (f.evaluate().isEmpty) return null;
        return tester
            .widget<Text>(find.descendant(of: f, matching: find.byType(Text)))
            .data;
      }

      controller.text = _chars(899);
      await tester.pump();
      expect(note(), isNull, reason: '899 — счётчика ещё нет');

      controller.text = _chars(900);
      await tester.pump();
      expect(note(), '900/1024');

      controller.text = _chars(1024);
      await tester.pump();
      expect(note(), '1024/1024', reason: 'ровно лимит — без предупреждения');

      controller.text = _chars(1025);
      await tester.pump();
      expect(note(), contains('1025/1024'));
      expect(note(), contains(warning));
    },
  );

  testWidgets(
    'AC:RL-send-caption-limit/3 — ровно 1024: подпись в body, текста нет',
    (tester) async {
      await _openDialog(tester, room, [_doc('a.pdf')], caption: _chars(1024));
      await _send(tester);
      expect(room.log, ['file:caption']);
      expect(room.fileExtras.single!['body'], _chars(1024));
      expect(room.texts, isEmpty);
      await _drain(tester);
    },
  );

  testWidgets(
    'AC:RL-send-caption-limit/5 — 1025: файлы без подписи, затем ОДИН текст в том же треде',
    (tester) async {
      await _openDialog(
        tester,
        room,
        [_doc('a.pdf'), _doc('b.pdf'), _doc('c.pdf')],
        caption: _chars(1025),
        threadRootEventId: r'$root',
      );
      await _send(tester);
      expect(room.log, ['file:-', 'file:-', 'file:-', 'text:1025']);
      expect(room.texts.single, _chars(1025));
      expect(room.textThreads.single, r'$root');
      await _drain(tester);
    },
  );

  testWidgets('AC:RL-send-caption-limit/6 — пустая подпись: текста нет', (
    tester,
  ) async {
    await _openDialog(tester, room, [_doc('a.pdf')]);
    await _send(tester);
    expect(room.log, ['file:-']);
    await _drain(tester);
  });

  testWidgets(
    'AC:RL-send-caption-limit/7 — ни один файл не ушёл: текст в композер, не в чат',
    (tester) async {
      room.failFiles = true;
      final restored = <String>[];
      await _openDialog(
        tester,
        room,
        [_doc('a.pdf')],
        caption: _chars(1025),
        onUnsentText: restored.add,
      );
      await _send(tester);
      expect(room.texts, isEmpty, reason: '«ушёл только текст» — дефект №52');
      expect(restored, [_chars(1025)]);
      await _drain(tester);
    },
  );

  test('AC:RL-send-caption-limit/8 — _reopen переносит подпись и колбэк', () {
    final code = File(
      'lib/pages/chat/send_file_dialog.dart',
    ).readAsStringSync();
    final start = code.indexOf('Future<void> _reopen(');
    final reopen = code.substring(start, code.indexOf('/// Плитка «+»', start));
    expect(reopen, contains('initialCaption: caption'));
    expect(reopen, contains('onUnsentText: widget.onUnsentText'));
  });

  group(
    'AC:RL-send-caption-limit/10 — узкая картинка не сжимается в полоску',
    () {
      test('скриншот 576×1280 (заявка №52) — ширина пузыря ≥160', () {
        final box = imageBubbleBox(w: 576, h: 1280, isSticker: false);
        expect(box.width, greaterThanOrEqualTo(160));
        expect(box.height, 256);
        expect(box.fit, BoxFit.contain, reason: 'скриншот не обрезается');
      });

      test('панорама 1280×100 — прежняя высота 32, без пустых полей', () {
        expect(imageBubbleBox(w: 1280, h: 100, isSticker: false).height, 32);
      });

      test('стикер сохраняет прежний минимум 32', () {
        expect(imageBubbleBox(w: 100, h: 1000, isSticker: true).width, 32);
      });

      test('MessageContent считает размер через imageBubbleBox', () {
        final code = File(
          'lib/pages/chat/events/message_content.dart',
        ).readAsStringSync();
        expect(code, contains('= imageBubbleBox('));
      });
    },
  );
}
