// ledger:RL-support-menu-navigation
// guard.render:real-widget — реальный MiniAppListContent и его onTap.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/mini_app_list_content.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/test_client.dart';

class _MatrixHarness extends MatrixState {
  _MatrixHarness(this.testClient) {
    userRoleService.applyOwnAccountData('@support:bots.liza.ru', {
      'role': 'ai',
    });
  }
  final Client testClient;
  @override
  Client get client => testClient;
}

class _CallbackRoom extends Room {
  _CallbackRoom({required super.id, required super.client});
  final callbacks = <Map<String, dynamic>>[];
  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    callbacks.add(content);
    return r'$callback';
  }
}

/// Payload по контракту support/cards.py; chunking целой выдачи проверяет Python.
/// Здесь границы одного payload доказываются реальным renderer maxItems=50.
Map<String, dynamic> _payload(int tickets) => {
  'msgtype': MiniAppListContent.msgType,
  'body': 'Мои обращения',
  'title': 'Мои обращения',
  if (tickets == 0) 'text': 'Обращений пока нет.',
  'items': [
    for (var i = tickets; i > 0; i--)
      {
        'item_id': 'ticket:$i',
        'title': '№$i — Проблема со входом',
        'subtitle': 'В работе',
        'action_button_id': 'support.my.show:$i',
      },
    {
      'item_id': 'support.my.new',
      'title': 'Новое обращение',
      'subtitle': 'Описать другую проблему',
      'action_button_id': 'support.my.new',
    },
  ],
};

void main() {
  setUpAll(() async {
    await L10n.delegate.load(const Locale('ru'));
    await L10n.delegate.load(const Locale('en'));
    if (Platform.environment['SUPPORT_MENU_VISUAL_DIR'] != null) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  for (final count in [0, 1, 49]) {
    for (final locale in ['ru', 'en']) {
      testWidgets(
        '$count обращений, $locale, 320px scale2: последняя строка Новое',
        (tester) async {
          // AC:RL-support-menu-navigation/10
          // AC:RL-support-menu-navigation/11
          // AC:RL-support-menu-navigation/20
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late Client client;
          await tester.runAsync(() async {
            client = await prepareTestClient(loggedIn: true);
          });
          client.backgroundSync = false;
          addTearDown(
            () => tester.runAsync(() => client.dispose(closeDatabase: true)),
          );
          final room = _CallbackRoom(id: '!support:example', client: client);
          final event = Event(
            eventId: r'$list',
            senderId: '@support:bots.liza.ru',
            originServerTs: DateTime(2026),
            type: EventTypes.Message,
            content: _payload(count),
            room: room,
          );
          final matrix = _MatrixHarness(client);
          addTearDown(matrix.userRoleService.dispose);
          String? fontFamily;
          final out = Platform.environment['SUPPORT_MENU_VISUAL_DIR'];
          if (out != null) {
            const path = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
            final loader = FontLoader('SupportVisual')
              ..addFont(
                Future.value(File(path).readAsBytesSync().buffer.asByteData()),
              );
            await tester.runAsync(loader.load);
            fontFamily = 'SupportVisual';
          }
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
              theme: ThemeData(fontFamily: fontFamily),
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
              home: Provider<MatrixState>.value(
                value: matrix,
                child: RepaintBoundary(
                  key: const Key('support-list-image'),
                  child: Scaffold(
                    body: MediaQuery(
                      data: const MediaQueryData(
                        textScaler: TextScaler.linear(2),
                      ),
                      child: SingleChildScrollView(
                        child: MiniAppListContent(
                          event: event,
                          textColor: Colors.black,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.byType(MiniAppListContent), findsOneWidget);
          expect(find.byType(InkWell), findsNWidgets(count + 1));
          if (count == 0) {
            expect(find.text('Обращений пока нет.'), findsOneWidget);
            expect(
              tester.getRect(find.text('Обращений пока нет.')).bottom,
              lessThan(640),
            );
          }
          if (count == 49) {
            expect(find.text('№49 — Проблема со входом'), findsOneWidget);
            expect(find.text('№1 — Проблема со входом'), findsOneWidget);
          }
          final semantics = tester.ensureSemantics();
          final newItem = find.text('Новое обращение');
          await tester.ensureVisible(newItem);
          await tester.pump(const Duration(milliseconds: 500));
          final lastRow = find.byType(InkWell).last;
          expect(
            find.descendant(of: lastRow, matching: newItem),
            findsOneWidget,
          );
          expect(tester.getRect(newItem).bottom, lessThanOrEqualTo(640));
          final semanticsData = tester.getSemantics(lastRow).getSemanticsData();
          expect(semanticsData.label, contains('Новое обращение'));
          expect(semanticsData.hasAction(ui.SemanticsAction.tap), isTrue);
          semantics.dispose();
          expect(tester.takeException(), isNull);
          if (out != null && locale == 'ru' && count != 1) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('support-list-image')),
            );
            final image = (await tester.runAsync(boundary.toImage))!;
            final bytes = await tester.runAsync(
              () => image.toByteData(format: ui.ImageByteFormat.png),
            );
            File(
              '$out/list-$count-320-ru-scale2.png',
            ).writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          }
          await tester.tap(newItem);
          await tester.pump();
          expect(room.callbacks, hasLength(1));
          expect(room.callbacks.single['button_id'], 'support.my.new');
          expect(
            room.callbacks.single['msgtype'],
            MiniAppListContent.callbackMsgType,
          );
          expect(room.callbacks.single['m.relates_to'], {
            'rel_type': MiniAppListContent.answerRelType,
            'event_id': r'$list',
          });
        },
      );
    }
  }
}
