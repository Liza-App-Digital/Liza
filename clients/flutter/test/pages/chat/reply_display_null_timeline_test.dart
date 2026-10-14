// GlitchTip #605 (Android 3769): `ReplyDisplay.build` делал `controller.timeline!`
// и ронял кадр, когда выбран ответ/правка, а лента в этот момент null — штатное
// окно перезагрузки (scrollDown/scrollToEventId обнуляют timeline) и dispose.
//
// Страж строит РЕАЛЬНЫЙ ReplyDisplay над РЕАЛЬНЫМ ChatController (перекрыт только
// room, initState не вызывается — образец scroll_down_null_timeline_test).
// Red-proof: вернуть `timeline: controller.timeline!` в reply_display.dart →
// tester.takeException() — Null check.
//
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/events/reply_content.dart';
import 'package:liza/pages/chat/reply_display.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

class _FakeChatController extends ChatController {
  _FakeChatController(this._fakeRoom);

  final Room _fakeRoom;

  @override
  Room get room => _fakeRoom;
}

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  Future<void> pump(WidgetTester tester, ChatController controller) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Provider<liza_matrix.MatrixState>.value(
          value: _TestMatrixState(client),
          child: Scaffold(body: ReplyDisplay(controller)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Event message(Room room) => Event(
    type: EventTypes.Message,
    eventId: '\$reply:example.invalid',
    senderId: '@bob:example.invalid',
    originServerTs: DateTime(2026, 10, 1, 12),
    room: room,
    content: {'msgtype': 'm.text', 'body': 'исходное'},
  );

  testWidgets('выбран ответ, timeline == null → цитата рисуется без падения', (
    tester,
  ) async {
    final room = Room(id: '!reply:example.invalid', client: client);
    final controller = _FakeChatController(room)..replyEvent = message(room);
    expect(controller.timeline, isNull);

    await pump(tester, controller);

    expect(tester.takeException(), isNull);
    expect(find.byType(ReplyContent), findsOneWidget);
  });

  testWidgets('режим правки, timeline == null → без падения', (tester) async {
    final room = Room(id: '!edit:example.invalid', client: client);
    final controller = _FakeChatController(room)..editEvent = message(room);

    await pump(tester, controller);

    expect(tester.takeException(), isNull);
    expect(find.text('исходное'), findsOneWidget);
  });
}
