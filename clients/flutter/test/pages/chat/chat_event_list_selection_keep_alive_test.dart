// ledger:RL-chat-selection-no-keepalive
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/chat_event_list.dart';
import 'package:liza/utils/channel_peek.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

// GlitchTip #2067/#2070/#2072–2076/#2101/#2102 (+ каскад #2068, #2009), macOS.
// Сообщение ленты на desktop обёрнуто в SelectionArea. Ушедшее за экран
// сообщение, попросившее keep-alive (InkWell с focus/hover-подсветкой,
// Swipeable на анимации), остаётся примонтированным, но SliverList его не
// раскладывает. Новый Text в нём регистрируется в SelectionArea без layout →
// _compareScreenOrder читает size → StateError, делегат остаётся рваным →
// следом RangeError в remove() при размонтировании.

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

class _FakeChatController extends Fake implements ChatController {
  _FakeChatController(this.room, this.timeline);

  @override
  final Room room;
  @override
  Timeline? timeline;
  @override
  String? activeThreadId;
  @override
  int? animateInEventIndex;
  @override
  String readMarkerEventId = '';
  @override
  String? scrollToEventIdMarker;
  @override
  final AutoScrollController scrollController = AutoScrollController();
  @override
  List<Event> selectedEvents = [];
  @override
  final Set<String> expandedEventIds = {};

  // Пустая лента сама просит историю после кадра.
  @override
  void requestHistory([dynamic _]) {}

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      '_FakeChatController';
}

final _tick = ValueNotifier<int>(0);
final _focus0 = FocusNode();

// Реплика ленты: элемент = SelectionArea, внутри InkWell (как кнопки/ссылки
// пузыря) и Text, появляющийся при перестройке (как квитанции по sync).
Widget _messageList({required bool keepAlives}) => MaterialApp(
  home: Scaffold(
    body: ValueListenableBuilder<int>(
      valueListenable: _tick,
      builder: (context, t, _) => ListView.custom(
        childrenDelegate: SliverChildBuilderDelegate(
          (context, i) => Padding(
            padding: const EdgeInsets.only(bottom: 60),
            child: SelectionArea(
              child: Column(
                children: [
                  Text('name $i'),
                  InkWell(
                    focusNode: i == 0 ? _focus0 : null,
                    onTap: () {},
                    child: Text('body $i'),
                  ),
                  if (t > 0) Text('receipt $i $t'),
                ],
              ),
            ),
          ),
          childCount: 100,
          addAutomaticKeepAlives: keepAlives,
        ),
      ),
    ),
  ),
);

Future<List<Object>> _focusScrollAwayAndRebuild(
  WidgetTester tester, {
  required bool keepAlives,
}) async {
  _tick.value = 0;
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  await tester.pumpWidget(_messageList(keepAlives: keepAlives));
  _focus0.requestFocus();
  await tester.pump();
  tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(5000);
  await tester.pump();
  expect(
    find.text('body 0', skipOffstage: false),
    keepAlives ? findsOneWidget : findsNothing,
    reason: 'сфокусированный InkWell держит ушедшее сообщение keep-alive',
  );
  final errors = <Object>[];
  // Сортировку selectables фреймворк гонит микрозадачей после кадра — её
  // исключение уходит в зону, а не в FlutterError, поэтому ловим зоной.
  await runZonedGuarded(() async {
    _tick.value++;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  }, (e, _) => errors.add(e));
  for (Object? e; (e = tester.takeException()) != null;) {
    errors.add(e!);
  }
  return errors;
}

void main() {
  testWidgets(
    'механизм: keep-alive сообщение под SelectionArea вне экрана + новый Text '
    '→ «RenderBox was not laid out: RenderParagraph»; без keep-alive — чисто',
    (tester) async {
      final withKeepAlive = await _focusScrollAwayAndRebuild(
        tester,
        keepAlives: true,
      );
      expect(
        withKeepAlive.join('\n'),
        contains('RenderBox was not laid out: RenderParagraph'),
        reason:
            'если Flutter починил сортировку selectables без layout — '
            'обходной addAutomaticKeepAlives:false можно пересмотреть',
      );

      final withoutKeepAlive = await _focusScrollAwayAndRebuild(
        tester,
        keepAlives: false,
      );
      expect(withoutKeepAlive, isEmpty);
    },
  );

  testWidgets(
    'ChatEventList на desktop не держит сообщения keep-alive (они под SelectionArea)',
    (tester) async {
      late final Client client;
      await tester.runAsync(() async {
        client = await prepareTestClient(loggedIn: true);
      });
      addTearDown(client.dispose);
      final room = Room(id: '!room:example.invalid', client: client);
      final timeline = buildPeekTimeline(room, []);
      addTearDown(timeline.cancelSubscriptions);
      final controller = _FakeChatController(room, timeline);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Provider<liza_matrix.MatrixState>.value(
            value: _TestMatrixState(client),
            child: Scaffold(body: ChatEventList(controller: controller)),
          ),
        ),
      );

      // pumpAndSettle не сходится: живой Client крутит фоновые таймеры.
      await tester.pump(const Duration(milliseconds: 500));
      final list = tester.widget<ListView>(find.byType(ListView));
      final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
      // Хост тестов — desktop (PlatformInfos.isMobile == false).
      expect(delegate.addAutomaticKeepAlives, isFalse);
    },
  );
}
