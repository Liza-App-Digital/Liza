// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-api-callback-query-native
//
// Клиентская половина настоящего callback_query (Даниэль Фурман 23.09: «Трушный
// callback_query без текстового «1» в чате: новый тип события»). Кнопка с
// флагом сервера `callback: true` шлёт событие com.liza.bot.callback (не текст),
// кнопка без флага (@bo_food «Оформить», старые сообщения) — номер текстом.
// Событие нажатия в ленте не видно. Реальный виджет XlButtonsContent.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/xl_buttons_content.dart';
import 'package:liza/utils/bot_callback.dart';
import 'package:liza/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/test_client.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    locale: const Locale('ru'),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: Provider<MatrixState>.value(
      value: MatrixState(),
      child: Scaffold(body: child),
    ),
  );

  Event card(Room room, List<Map<String, Object?>> buttons) => Event(
    type: EventTypes.Message,
    content: {
      'msgtype': 'm.text',
      'body': 'Подтвердить?',
      'com.liza.xl_buttons': buttons,
      'com.liza.xl_text_html': 'Подтвердить?',
    },
    eventId: '\$card',
    senderId: '@bot_father:liza.local',
    originServerTs: DateTime.now(),
    room: room,
  );

  List<String> sentTo(String path) => FakeMatrixApi.calledEndpoints.entries
      .where((e) => e.key.contains(path))
      .expand((e) => e.value)
      .map((b) => b.toString())
      .toList();

  Future<void> tapButton(
    WidgetTester tester,
    Room room,
    Map<String, Object?> button,
  ) async {
    await tester.pumpWidget(
      wrap(
        XlButtonsContent(
          event: card(room, [button]),
          textColor: const Color(0xFF000000),
          linkColor: const Color(0xFF0000FF),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    final btn = find.text(button['title']! as String);
    expect(btn, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(btn);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
  }

  Future<Room> roomOf(WidgetTester tester) async {
    late final Client client;
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true);
    });
    addTearDown(client.dispose);
    FakeMatrixApi.calledEndpoints.clear();
    final room = Room(id: '!r:liza.local', client: client);
    client.rooms.add(room);
    return room;
  }

  testWidgets(
    'кнопка с callback:true → событие com.liza.bot.callback с номером и id сообщения, без текста',
    (tester) async {
      // AC:RL-bot-api-callback-query-native/8
      final room = await roomOf(tester);
      await tapButton(tester, room, {
        'index': '1',
        'title': 'Да',
        'url': '',
        'callback': true,
      });

      final events = sentTo('/send/$botCallbackEventType/');
      expect(events, hasLength(1));
      expect(jsonDecode(events.single), {
        'index': '1',
        'm.relates_to': {
          'rel_type': botCallbackEventType,
          'event_id': '\$card',
        },
      });
      expect(
        sentTo('/send/m.room.message/'),
        isEmpty,
        reason: 'в ленте не должно появиться «1»',
      );
      // Нажатая кнопка отмечена галочкой — иначе тап выглядит несработавшим.
      expect(find.byIcon(Icons.check), findsOneWidget);
    },
  );

  testWidgets(
    'кнопка без флага (как «Оформить» у @bo_food) → номер текстом, события нет',
    (tester) async {
      // AC:RL-bot-api-callback-query-native/8
      final room = await roomOf(tester);
      await tapButton(tester, room, {
        'index': 'bofood_checkout',
        'title': 'Оформить',
      });

      expect(
        sentTo(
          '/send/m.room.message/',
        ).any((b) => b.contains('bofood_checkout')),
        isTrue,
      );
      expect(sentTo('/send/$botCallbackEventType/'), isEmpty);
    },
  );

  test(
    'событие нажатия не видно в ленте (даже при показе неизвестных событий)',
    () async {
      // AC:RL-bot-api-callback-query-native/9
      final client = await prepareTestClient(loggedIn: true);
      final room = Room(id: '!r:liza.local', client: client);
      final press = Event(
        type: botCallbackEventType,
        content: botCallbackContent(index: '1', eventId: '\$card'),
        eventId: '\$press',
        senderId: '@me:liza.local',
        originServerTs: DateTime.now(),
        room: room,
      );
      expect(press.isBotCallbackEvent, isTrue);
      expect(press.isVisibleInGui, isFalse);
      // В превью списка чатов не попадёт: SDK берёт lastEvent только из этих типов.
      expect(
        client.roomPreviewLastEvents.contains(botCallbackEventType),
        isFalse,
      );
      await client.dispose(closeDatabase: true);
    },
  );
}
