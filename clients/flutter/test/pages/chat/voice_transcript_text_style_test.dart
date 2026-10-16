// ledger:RL-ai-dm-voice-auto-transcript
// Расшифровка под голосовым выглядит как текстовое сообщение: те же отступы от
// краёв пузыря, тот же зазор до времени, время в том же углу; пузырь не меняет
// ширину, когда текст появляется.
//
// Роман, 15.10 (голосом): «…чисто это поверстки отступы, чтобы совпадали как в
// сообщениях. Ну, немного текст съезжает как-то. Надо, чтобы отступы совпадали как
// в сообщениях размеры, чтобы идентичные были тексты и так далее. Ну, чтобы
// стилистически выглядело как сообщение.»
//
// Меряется РЕАЛЬНЫЙ `Message` (пузырь `BubbleBackground` целиком) — эталон берётся
// с текстового `Message` в той же ленте, а не числом из кода. Шрифт в host-тестах —
// Ahem: доказываются координаты, не переносы строк (их — manual AC-17).
// Спека: docs/superpowers/specs/2026-10-15-voice-transcript-text-style-design.md
//
// Red-proof (2026-10-15, на коде до правки): AC-9/10 — L/R 28 вместо 16;
// AC-11 — время R16 вместо 12; AC-12 — зазор 2 вместо 4; AC-15 — подпись 28.
//
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/pages/chat/events/message_time.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

const _long =
    'Там единственное, обратите внимание, чисто это поверстки отступы, чтобы '
    'совпадали как в сообщениях. Ну, немного текст съезжает как-то. Надо, '
    'чтобы отступы совпадали как в сообщениях размеры.';
const _short = 'Да.';
const _caption = 'Подпись к голосовому';
const _eps = 0.5;

/// Геометрия пузыря относительно его краёв.
class _Geo {
  _Geo({
    required this.left,
    required this.right,
    required this.timeRight,
    required this.timeBottom,
    required this.gapToTime,
  });
  final double left, right, timeRight, timeBottom, gapToTime;

  @override
  String toString() =>
      'L=$left R=$right timeR=$timeRight timeB=$timeBottom gap=$gapToTime';
}

void main() {
  late Client client;
  late _TestMatrixState matrix;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    matrix = _TestMatrixState(client);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  Room buildRoom({bool protected = false}) {
    final room = Room(id: '!room:example.invalid', client: client);
    if (protected) {
      room.setState(
        StrippedStateEvent(
          type: channelNoForwardsState,
          stateKey: '',
          senderId: '@owner:example.invalid',
          content: {'enabled': true},
        ),
      );
    }
    return room;
  }

  String sender(bool own) => own ? client.userID! : '@author:example.invalid';

  Event text(Room room, String body) => Event(
    type: EventTypes.Message,
    eventId: '\$text:example.invalid',
    senderId: sender(false),
    originServerTs: DateTime(2026, 10, 15, 12, 40),
    room: room,
    content: {'msgtype': 'm.text', 'body': body},
  );

  Event voice(Room room, {bool own = false, bool caption = false}) => Event(
    type: EventTypes.Message,
    eventId: '\$voice:example.invalid',
    senderId: sender(own),
    originServerTs: DateTime(2026, 10, 15, 12, 40),
    room: room,
    content: {
      'msgtype': 'm.audio',
      'body': caption ? _caption : 'Голосовое сообщение.ogg',
      'filename': 'Голосовое сообщение.ogg',
      'url': 'mxc://example.invalid/voice',
      'org.matrix.msc3245.voice': <String, dynamic>{},
      'info': {'duration': 19000, 'size': 30000, 'mimetype': 'audio/ogg'},
    },
  );

  Future<void> pumpMessage(
    WidgetTester tester,
    Event event, {
    double width = 600,
  }) async {
    final timeline = Timeline(
      room: event.room,
      chunk: TimelineChunk(events: [event]),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Provider<liza_matrix.MatrixState>.value(
            value: matrix,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: ListView.builder(
                    reverse: true,
                    controller: scrollController,
                    itemCount: 1,
                    itemBuilder: (context, i) => Message(
                      event,
                      timeline: timeline,
                      scrollController: scrollController,
                      colors: const [Colors.grey, Colors.blue],
                      onSelect: (_) {},
                      onInfoTab: (_) {},
                      scrollToEventId: (_) {},
                      onSwipe: () {},
                      onMention: () {},
                      onEdit: () {},
                      enterThread: null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
  }

  Future<void> transcribe(WidgetTester tester, Event event, String text) =>
      tester.runAsync(() async {
        matrix.transcriptionService.clearCache();
        matrix.transcriptionService.debugFetch = (_) async => text;
        await matrix.transcriptionService.transcribe(event);
      });

  /// Rect абзаца: SelectableText → EditableText; Text/HtmlMessage → RichText.
  Rect paragraph(WidgetTester tester, String needle) {
    final editable = find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text.contains(needle),
    );
    if (editable.evaluate().isNotEmpty) return tester.getRect(editable.first);
    final rich = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains(needle),
    );
    expect(rich, findsOneWidget, reason: 'абзац «$needle»');
    return tester.getRect(rich);
  }

  Rect bubbleRect(WidgetTester tester) =>
      tester.getRect(find.byType(BubbleBackground).first);

  _Geo geometry(WidgetTester tester, String needle) {
    final bubble = bubbleRect(tester);
    final para = paragraph(tester, needle);
    final time = tester.getRect(find.byType(MessageTime).first);
    return _Geo(
      left: para.left - bubble.left,
      right: bubble.right - para.right,
      timeRight: bubble.right - time.right,
      timeBottom: bubble.bottom - time.bottom,
      gapToTime: time.top - para.bottom,
    );
  }

  /// Эталон — текстовое сообщение с длинным текстом (во всю ширину строки).
  Future<_Geo> textReference(WidgetTester tester, {double width = 600}) async {
    await pumpMessage(tester, text(buildRoom(), _long), width: width);
    return geometry(tester, 'единственное');
  }

  // AC:RL-ai-dm-voice-auto-transcript/16 — ∀ клетки: AC-9…12 в каждой
  for (final width in [360.0, 430.0, 1000.0]) {
    for (final own in [false, true]) {
      for (final protected in [false, true]) {
        for (final withCaption in [false, true]) {
          final cell =
              'лента $width, ${own ? 'свой' : 'чужой'}, '
              '${protected ? 'защищённый (Text)' : 'SelectableText'}, '
              '${withCaption ? 'с подписью' : 'без подписи'}';
          testWidgets(
            'длинная расшифровка стоит как текст сообщения — $cell — '
            'AC:RL-ai-dm-voice-auto-transcript/9 AC:RL-ai-dm-voice-auto-transcript/10 '
            'AC:RL-ai-dm-voice-auto-transcript/11 AC:RL-ai-dm-voice-auto-transcript/12',
            (tester) async {
              final ref = await textReference(tester, width: width);
              final v = voice(
                buildRoom(protected: protected),
                own: own,
                caption: withCaption,
              );
              await transcribe(tester, v, _long);
              await pumpMessage(tester, v, width: width);
              final got = geometry(tester, 'единственное');

              expect(
                got.left,
                closeTo(ref.left, _eps),
                reason: 'AC-9 $got / $ref',
              );
              expect(
                got.right,
                closeTo(ref.right, _eps),
                reason: 'AC-10 $got / $ref',
              );
              expect(
                got.timeRight,
                closeTo(ref.timeRight, _eps),
                reason: 'AC-11',
              );
              expect(
                got.timeBottom,
                closeTo(ref.timeBottom, _eps),
                reason: 'AC-11',
              );
              if (!withCaption) {
                // с подписью под расшифровкой стоит подпись, а не время
                expect(
                  got.gapToTime,
                  closeTo(ref.gapToTime, _eps),
                  reason: 'AC-12',
                );
              }
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }

  testWidgets(
    'короткая расшифровка: отступ слева, время и зазор как у текста — '
    'AC:RL-ai-dm-voice-auto-transcript/9 AC:RL-ai-dm-voice-auto-transcript/11 '
    'AC:RL-ai-dm-voice-auto-transcript/12',
    (tester) async {
      final ref = await textReference(tester);
      final v = voice(buildRoom());
      await transcribe(tester, v, _short);
      await pumpMessage(tester, v);
      final got = geometry(tester, _short);
      expect(got.left, closeTo(ref.left, _eps), reason: '$got / $ref');
      expect(got.timeRight, closeTo(ref.timeRight, _eps));
      expect(got.gapToTime, closeTo(ref.gapToTime, _eps));
    },
  );

  // AC:RL-ai-dm-voice-auto-transcript/13 — пузырь не прыгает при появлении текста
  for (final width in [360.0, 1000.0]) {
    testWidgets(
      'ширина пузыря до и после расшифровки одинакова (лента $width) — '
      'AC:RL-ai-dm-voice-auto-transcript/13',
      (tester) async {
        final room = buildRoom();
        await pumpMessage(tester, voice(room), width: width);
        final before = bubbleRect(tester).width;
        for (final t in [_short, _long]) {
          final v = voice(room);
          await transcribe(tester, v, t);
          await pumpMessage(tester, v, width: width);
          expect(
            bubbleRect(tester).width,
            closeTo(before, _eps),
            reason: '«${t.substring(0, 3)}…»',
          );
        }
      },
    );
  }

  testWidgets('голосовое без расшифровки — время на прежних 16 от края — '
      'AC:RL-ai-dm-voice-auto-transcript/14', (tester) async {
    await pumpMessage(tester, voice(buildRoom()));
    final bubble = bubbleRect(tester);
    final time = tester.getRect(find.byType(MessageTime).first);
    expect(bubble.right - time.right, closeTo(16, _eps));
  });

  testWidgets('подпись под голосовым — 16 от края, как у текста — '
      'AC:RL-ai-dm-voice-auto-transcript/15', (tester) async {
    final ref = await textReference(tester);
    await pumpMessage(tester, voice(buildRoom(), caption: true));
    final bubble = bubbleRect(tester);
    final para = paragraph(tester, _caption);
    expect(para.left - bubble.left, closeTo(ref.left, _eps));
  });
}
