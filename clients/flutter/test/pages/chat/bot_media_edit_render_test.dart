// ledger:RL-bot-api-client-compat
// guard.render:real-widget
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/image_bubble.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/pages/chat/events/message_content.dart';
import 'package:liza/pages/chat/events/video_player.dart';
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

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!media:example.invalid', client: client);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  for (final type in [MessageTypes.Image, MessageTypes.Video]) {
    // AC:RL-bot-api-client-compat/5
    testWidgets(
      'Message рисует photo→$type через m.replace, ID исходного цел',
      (tester) async {
        final original = Event(
          type: EventTypes.Message,
          eventId: '\$original',
          senderId: '@custom:bots.liza.ru',
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
          room: room,
          content: {
            'msgtype': MessageTypes.Image,
            'body': 'old.jpg',
            'url': 'mxc://example.invalid/old',
            'info': {'mimetype': 'image/jpeg', 'w': 400, 'h': 300},
          },
        );
        final newContent = {
          'msgtype': type,
          'body': type == MessageTypes.Image ? 'new.jpg' : 'new.mp4',
          'url': 'mxc://example.invalid/new',
          'info': {
            'mimetype': type == MessageTypes.Image ? 'image/jpeg' : 'video/mp4',
            'w': 400,
            'h': 300,
            'thumbnail_url': 'mxc://example.invalid/thumbnail',
          },
        };
        final edit = Event(
          type: EventTypes.Message,
          eventId: '\$edit',
          senderId: original.senderId,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(2000),
          room: room,
          content: {
            ...newContent,
            'body': '* ${newContent['body']}',
            'm.new_content': newContent,
            'm.relates_to': {
              'rel_type': RelationshipTypes.edit,
              'event_id': original.eventId,
            },
          },
        );
        final timeline = Timeline(
          room: room,
          chunk: TimelineChunk(events: [edit, original]),
        );
        addTearDown(timeline.cancelSubscriptions);
        final display = original.getDisplayEvent(timeline);
        expect(original.eventId, '\$original');
        expect(display.eventId, '\$edit');
        expect(display.messageType, type);
        expect(display.content['url'], 'mxc://example.invalid/new');

        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('ru'),
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
              home: Provider<liza_matrix.MatrixState>.value(
                value: _TestMatrixState(client),
                child: Scaffold(
                  body: ListView(
                    controller: scroll,
                    children: [
                      Message(
                        original,
                        timeline: timeline,
                        scrollController: scroll,
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
                ),
              ),
            ),
          );
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        });
        final content = tester.widget<MessageContent>(
          find.byType(MessageContent),
        );
        expect(content.event.eventId, '\$edit');
        expect(content.event.messageType, type);
        if (type == MessageTypes.Image) {
          final image = tester.widget<ImageBubble>(find.byType(ImageBubble));
          expect(image.event.content['url'], 'mxc://example.invalid/new');
          expect(find.byType(EventVideoPlayer), findsNothing);
        } else {
          final video = tester.widget<EventVideoPlayer>(
            find.byType(EventVideoPlayer),
          );
          expect(video.event.content['url'], 'mxc://example.invalid/new');
          expect(find.byType(ImageBubble), findsNothing);
        }
        expect(original.eventId, '\$original');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
