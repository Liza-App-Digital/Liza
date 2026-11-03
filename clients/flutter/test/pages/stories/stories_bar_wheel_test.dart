// ignore_for_file: depend_on_referenced_packages
// ledger:RL-horizontal-mouse-wheel
//
// РЕАЛЬНЫЙ виджет StoriesBar внутри вертикального скролла (как в списке
// чатов): вертикальное колесо мыши над лентой двигает ЛЕНТУ, а не список
// чатов (залипание скролла на сториз, Windows, 02.11.2026).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/stories/stories_bar.dart';
import 'package:liza/utils/stories/frequent_contacts.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/test_client.dart';

class _MatrixWithClient extends MatrixState {
  _MatrixWithClient(this.testClient, this.prefs);

  final Client testClient;
  final SharedPreferences prefs;

  @override
  Client get client => testClient;

  @override
  SharedPreferences get store => prefs;
}

void main() {
  late Client client;
  final vertical = ScrollController();

  setUp(FrequentContactsCache.instance.reset);

  Future<void> addDm(String peer, int messages) async {
    final roomId = '!dm-${peer.hashCode}:example.invalid';
    final room = Room(id: roomId, client: client);
    client.rooms.add(room);
    final direct = Map<String, Object?>.from(
      client.accountData['m.direct']?.content ?? const {},
    );
    direct[peer] = [roomId];
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: direct,
    );
    room.setState(
      Event(
        eventId: '\$m-$roomId',
        senderId: peer,
        originServerTs: DateTime.now(),
        type: EventTypes.RoomMember,
        stateKey: peer,
        content: {'membership': 'join', 'displayname': peer.localpart},
        room: room,
      ),
    );
    for (var i = 0; i < messages; i++) {
      final e = MatrixEvent(
        eventId: '\$e-$roomId-$i',
        senderId: peer,
        originServerTs: DateTime.now().subtract(Duration(minutes: i + 1)),
        type: EventTypes.Message,
        content: const {'msgtype': 'm.text', 'body': 'hi'},
      );
      await client.database.storeEventUpdate(
        roomId,
        e,
        EventUpdateType.timeline,
        client,
      );
      room.lastEvent ??= Event.fromMatrixEvent(e, room);
    }
  }

  ScrollPosition barPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(StoriesBar),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  Future<void> pumpBar(WidgetTester tester) async {
    late SharedPreferences prefs;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      client = await prepareTestClient(loggedIn: true);
      await client.abortSync();
      client.rooms.clear();
      client.accountData.remove('m.direct');
      for (var i = 0; i < 10; i++) {
        await addDm('@peer$i:example.invalid', 10 - i);
      }
    });
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: _MatrixWithClient(client, prefs),
        child: MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              controller: vertical,
              slivers: [
                const SliverToBoxAdapter(child: StoriesBar()),
                SliverToBoxAdapter(child: Container(height: 2000)),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    await tester.pump();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(null);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 40));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.dispose(closeDatabase: true);
    });
  }

  Future<void> wheel(
    WidgetTester tester,
    Offset at,
    Offset delta, {
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) async {
    final pointer = TestPointer(1, kind);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.sendEventToBinding(pointer.scroll(delta));
    await tester.pump();
  }

  Offset over(WidgetTester tester, Finder f) => tester.getCenter(f.first);

  testWidgets(
    'AC:RL-horizontal-mouse-wheel/6 колесо над аватаркой двигает ленту, не список',
    (tester) async {
      await pumpBar(tester);
      final bar = barPosition(tester);
      expect(bar.maxScrollExtent, greaterThan(0), reason: 'лента переполнена');

      final avatar = over(tester, find.byType(StoriesBar));
      await wheel(tester, avatar, const Offset(0, 60));
      expect(bar.pixels, greaterThan(0));
      expect(vertical.offset, 0);

      final after = bar.pixels;
      await wheel(tester, avatar, const Offset(0, -20));
      expect(bar.pixels, lessThan(after));
      expect(vertical.offset, 0);
      await teardown(tester);
    },
  );

  testWidgets(
    'AC:RL-horizontal-mouse-wheel/7 колесо над кнопкой «+» двигает ленту',
    (tester) async {
      await pumpBar(tester);
      final bar = barPosition(tester);
      final plus = over(tester, find.byIcon(Icons.add_outlined));
      await wheel(tester, plus, const Offset(0, 60));
      expect(bar.pixels, greaterThan(0));
      expect(vertical.offset, 0);
      await teardown(tester);
    },
  );

  testWidgets(
    'AC:RL-horizontal-mouse-wheel/8 у края ленты колесо уходит списку',
    (tester) async {
      await pumpBar(tester);
      final bar = barPosition(tester);
      final at = over(tester, find.byType(StoriesBar));

      // Левый край, колесо «назад» → родитель не двигается вверх (он на 0),
      // а вперёд до упора → дальше колесо крутит вертикальный список.
      bar.jumpTo(bar.maxScrollExtent);
      await tester.pump();
      await wheel(tester, at, const Offset(0, 60));
      expect(bar.pixels, bar.maxScrollExtent);
      expect(vertical.offset, greaterThan(0));
      await teardown(tester);
    },
  );

  testWidgets(
    'AC:RL-horizontal-mouse-wheel/10 трекпад не перехватывается обёрткой',
    (tester) async {
      await pumpBar(tester);
      final bar = barPosition(tester);
      final at = over(tester, find.byType(StoriesBar));
      await wheel(
        tester,
        at,
        const Offset(0, 60),
        kind: PointerDeviceKind.trackpad,
      );
      expect(bar.pixels, 0);
      await teardown(tester);
    },
  );
}
