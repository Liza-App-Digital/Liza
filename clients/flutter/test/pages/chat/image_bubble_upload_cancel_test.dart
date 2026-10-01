// ledger:RL-pending-send-cancel
// Страж РЕАЛЬНОГО виджета ImageBubble (guard.render:real-widget).
//
// LABA-2622: «Нет возможности отменить загрузку изображения, когда оно
// находится в очереди на отправку». У видео и плиток альбома крестик был, у
// одиночного фото — ни прогресса, ни отмены.
//
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/image_bubble.dart';
import 'package:liza/utils/upload_progress_tracker.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

void main() {
  late Client client;
  late Room room;
  final tracker = UploadProgressTracker.instance;
  const txid = 'txn-photo-1';

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!photo:example.invalid', client: client);
  });

  tearDown(() async {
    tracker.unregister(txid);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  Event photo({
    EventStatus status = EventStatus.sending,
    String? sender,
    String msgtype = MessageTypes.Image,
  }) => Event(
    type: msgtype == MessageTypes.Sticker
        ? EventTypes.Sticker
        : 'm.room.message',
    eventId: status.isSent ? '\$photo:example.invalid' : txid,
    senderId: sender ?? client.userID!,
    originServerTs: DateTime(2026, 9, 30, 10),
    room: room,
    status: status,
    content: {
      'msgtype': msgtype,
      'body': 'photo.jpg',
      'info': {'mimetype': 'image/jpeg', 'w': 800, 'h': 600},
    },
    unsigned: status.isSent ? null : {'transaction_id': txid},
  );

  Future<void> pumpBubble(
    WidgetTester tester,
    Event event, {
    double width = 300,
    double height = 225,
    bool longPressSelect = false,
    VoidCallback? onTap,
  }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Provider<liza_matrix.MatrixState>.value(
            value: _TestMatrixState(client),
            child: Scaffold(
              body: Center(
                child: ImageBubble(
                  event,
                  width: width,
                  height: height,
                  fit: BoxFit.cover,
                  longPressSelect: longPressSelect,
                  onTap: onTap,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
  }

  final cancelKey = find.byKey(const ValueKey('upload-cancel-$txid'));

  group('AC:RL-pending-send-cancel/1 — крестик только на своём '
      'отправляющемся фото', () {
    testWidgets('своё, отправляется → крестик есть', (tester) async {
      tracker.register(txid);
      await pumpBubble(tester, photo());
      expect(cancelKey, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('своё, упало на обрыве, серия его дошлёт («в очереди», '
        'ждёт сеть) → крестик есть', (tester) async {
      tracker.register(txid);
      tracker.claimForSeries([txid]);
      addTearDown(() => tracker.releaseFromSeries([txid]));
      await pumpBubble(tester, photo(status: EventStatus.error));
      expect(cancelKey, findsOneWidget);
    });

    for (final (label, build) in <(String, Event Function())>[
      ('отправлено', () => photo(status: EventStatus.synced)),
      ('чужое', () => photo(sender: '@bob:example.invalid')),
      ('стикер', () => photo(msgtype: MessageTypes.Sticker)),
    ]) {
      testWidgets('$label → крестика нет', (tester) async {
        tracker.register(txid);
        await pumpBubble(tester, build());
        expect(find.byKey(const ValueKey('upload-cancel-$txid')), findsNothing);
        expect(find.byIcon(Icons.close), findsNothing);
      });
    }
  });

  testWidgets('AC:RL-pending-send-cancel/2 — тап по крестику ставит флаг '
      'отмены и НЕ открывает просмотр', (tester) async {
    tracker.register(txid);
    var bubbleTaps = 0;
    await pumpBubble(tester, photo(), onTap: () => bubbleTaps++);

    await tester.runAsync(() async {
      await tester.tap(cancelKey);
      await tester.pump();
    });

    expect(tracker.isCancelled(txid), isTrue);
    expect(bubbleTaps, 0, reason: 'крестик перехватывает тап у пузыря');
  });

  testWidgets('AC:RL-pending-send-cancel/6 — в режиме выделения тап по '
      'крестику НЕ отменяет отправку', (tester) async {
    tracker.register(txid);
    await pumpBubble(tester, photo(), longPressSelect: true);

    await tester.runAsync(() async {
      await tester.tap(cancelKey, warnIfMissed: false);
      await tester.pump();
    });

    expect(tracker.isCancelled(txid), isFalse);
  });

  testWidgets('AC:RL-pending-send-cancel/7 — панорама высотой 32 px: без '
      'overflow, только крестик', (tester) async {
    tracker.register(txid);
    await pumpBubble(tester, photo(), width: 300, height: 32);

    expect(tester.takeException(), isNull);
    expect(cancelKey, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('AC:RL-pending-send-cancel/7 — узкое фото (100×100) — '
      'компактный оверлей без overflow', (tester) async {
    tracker.register(txid);
    await pumpBubble(tester, photo(), width: 100, height: 100);

    expect(tester.takeException(), isNull);
    expect(cancelKey, findsOneWidget);
  });

  testWidgets('AC:RL-pending-send-cancel/8 — упавшее одиночное фото вне '
      'серии: ↻-оверлея на превью нет (UX упавших фото прежний)', (
    tester,
  ) async {
    await pumpBubble(tester, photo(status: EventStatus.error));

    expect(find.byKey(const ValueKey('upload-retry-$txid')), findsNothing);
    expect(cancelKey, findsNothing);
  });
}
