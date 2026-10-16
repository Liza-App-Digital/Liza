// ledger:RL-bot-api-send-media-group
// Страж РЕАЛЬНОГО виджета Message → GalleryBubble (guard.render:real-widget).
//
// Альбом от БОТА (sendMediaGroup, liza-bot-api 1.6.0) рисует уже установленный
// клиент — сборка не нужна, поэтому контракт «сервер → сетка» держим здесь:
// content событий — ровно тот, что выдал локальный liza-bot-api 15.10 (смоук
// 10 картинок), отправитель — бот, а не владелец клиента.
//
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/gallery.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

Widget _wrap(Widget child, Client client) => MaterialApp(
  locale: const Locale('ru'),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Provider<liza_matrix.MatrixState>.value(
    value: _TestMatrixState(client),
    child: Scaffold(body: child),
  ),
);

const _bot = '@club_xl_bot:example.invalid';
const _caption = 'Смоук sendMediaGroup: 10 картинок';

void main() {
  late Client client;
  late Room room;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!bot:example.invalid', client: client);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  // Форма media_group.py::_assemble_group: подпись в body+gallery.caption только
  // на i==0, имя файла — в filename; у остальных body = имя файла.
  Event botItem(int i, int n) => Event(
    type: EventTypes.Message,
    eventId: '\$bot$i:example.invalid',
    senderId: _bot,
    originServerTs: DateTime.now(),
    room: room,
    status: EventStatus.synced,
    content: {
      'msgtype': MessageTypes.Image,
      'body': i == 0 ? _caption : 'pic$i.jpg',
      if (i == 0) 'filename': 'pic$i.jpg',
      'url': 'mxc://example.invalid/pic$i',
      'info': {'mimetype': 'image/jpeg', 'size': 2000, 'w': 400, 'h': 300},
      'com.liza.gallery': {
        'id': '4a127859',
        'i': i,
        'n': n,
        if (i == 0) 'caption': _caption,
      },
    },
  );

  Future<void> pumpAlbum(WidgetTester tester, List<Event> members) async {
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: members.reversed.toList()),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _wrap(
          ListView(
            controller: scrollController,
            children: [
              Message(
                members.first,
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
            ],
          ),
          client,
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
  }

  for (final (n, columns) in [(2, 2), (4, 2), (10, 3)]) {
    testWidgets(
      'AC:RL-bot-api-send-media-group/12 — альбом бота из $n картинок: одна '
      'сетка в $columns колонки, все $n ячеек, без фантомов, подпись один раз',
      (tester) async {
        await pumpAlbum(tester, [for (var i = 0; i < n; i++) botItem(i, n)]);

        expect(find.byType(GalleryBubble), findsOneWidget);
        final grid = tester.widget<GridView>(
          find.descendant(
            of: find.byType(GalleryBubble),
            matching: find.byType(GridView),
          ),
        );
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, columns);
        expect((grid.childrenDelegate as SliverChildBuilderDelegate)
            .estimatedChildCount, n);
        expect(
          find.descendant(
            of: find.byType(GalleryBubble),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
          reason: 'n == факту — спиннеров-фантомов нет',
        );
        expect(find.text(_caption), findsOneWidget);
      },
    );
  }
}
