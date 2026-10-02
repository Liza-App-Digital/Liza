// ledger:RL-scroll-to-event-null-timeline
//
// GlitchTip #2088 (сборка 3745, Android): `ChatController.scrollToEventId()`
// начинался с `timeline!` и падал «Null check operator used on a null value»,
// когда его звал диалог закреплённых сообщений после двух await (загрузка
// закрепов на канале ~20 КБ/с + выбор в попапе): за это время лента
// перезагружалась либо чат закрывали (dispose обнуляет timeline).
//
// Страж зовёт РЕАЛЬНЫЙ ChatController.scrollToEventId (не реплику):
// _FakeChatController перекрывает только room, initState не вызывается — State
// не смонтирован, как после dispose (образец scroll_down_null_timeline_test).

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/chat.dart';

import '../../utils/test_client.dart';

class _FakeChatController extends ChatController {
  _FakeChatController(this._fakeRoom);

  final Room _fakeRoom;

  @override
  Room get room => _fakeRoom;
}

void main() {
  late Client client;

  setUpAll(() async {
    client = await prepareTestClient(loggedIn: true);
  });

  tearDownAll(() async {
    await client.dispose(closeDatabase: true);
  });

  Room room() => Room(id: '!pinned:fakeServer.notExisting', client: client);

  // AC:RL-scroll-to-event-null-timeline/1
  test('AC-1: scrollToEventId() при timeline == null без загрузки (чат закрыт) '
      'не падает и не запускает перезагрузку', () async {
    final controller = _FakeChatController(room());
    expect(controller.timeline, isNull);
    expect(controller.loadTimelineFuture, isNull);

    await controller.scrollToEventId(r'$pinned');

    expect(controller.timeline, isNull);
    expect(controller.loadTimelineFuture, isNull);
  });

  // AC:RL-scroll-to-event-null-timeline/2
  test('AC-2: scrollToEventId() при timeline == null во время загрузки ждёт её '
      'и не падает, если ленты так и нет', () async {
    final controller = _FakeChatController(room());
    final load = Completer<void>();
    controller.loadTimelineFuture = load.future;

    var done = false;
    final call = controller
        .scrollToEventId(r'$pinned')
        .then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse, reason: 'ждём текущую загрузку ленты');

    load.complete();
    await call;

    expect(done, isTrue);
    expect(
      controller.loadTimelineFuture,
      same(load.future),
      reason: 'свою перезагрузку не запускаем',
    );
  });

  // AC:RL-scroll-to-event-null-timeline/3
  test('AC-3: scrollToEventId() не пробрасывает ошибку упавшей загрузки ленты '
      '(её уже показал _tryLoadTimeline)', () async {
    final controller = _FakeChatController(room());
    final load = Completer<void>();
    controller.loadTimelineFuture = load.future;

    final call = controller.scrollToEventId(r'$pinned');
    load.completeError(Exception('timeline load failed'));

    await expectLater(call, completes);
    expect(controller.timeline, isNull);
  });
}
