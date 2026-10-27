// ledger:RL-windows-video-viewer-playback
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/image_viewer/image_viewer.dart';
import 'package:liza/utils/platform_infos.dart';

import '../../utils/test_client.dart';

void main() {
  late Room room;

  setUpAll(() async {
    room = Room(id: '!r:x', client: await prepareTestClient());
  });

  Event media(String id, String msgtype) => Event(
    type: EventTypes.Message,
    content: {'msgtype': msgtype, 'body': id},
    eventId: id,
    senderId: '@a:x',
    originServerTs: DateTime.now(),
    room: room,
  );

  // AC:RL-windows-video-viewer-playback/1
  test('плеер включён везде, кроме Linux', () {
    expect(videoPlayerSupported(isWindows: true, isLinux: false), isTrue);
    expect(
      videoPlayerSupported(isWindows: false, isLinux: false),
      isTrue,
      reason: 'android/iOS/macOS',
    );
    expect(videoPlayerSupported(isWindows: false, isLinux: true), isFalse);
  });

  // AC:RL-windows-video-viewer-playback/2
  test('альбом из двух видео: тап по второму открывает его', () {
    // timeline.events — от новых к старым.
    final v2 = media(r'$v2', MessageTypes.Video);
    final v1 = media(r'$v1', MessageTypes.Video);
    final (events, index) = viewerEvents([v2, v1], v2, supportsVideo: true);
    expect(events.map((e) => e.eventId), [r'$v1', r'$v2']);
    expect(events[index].eventId, r'$v2');
  });

  // AC:RL-windows-video-viewer-playback/3
  test('смешанная лента: индекс тапнутого видео, порядок сохранён', () {
    final img2 = media(r'$i2', MessageTypes.Image);
    final txt = media(r'$t', MessageTypes.Text);
    final vid = media(r'$v', MessageTypes.Video);
    final img1 = media(r'$i1', MessageTypes.Image);
    final (events, index) = viewerEvents(
      [img2, txt, vid, img1],
      vid,
      supportsVideo: true,
    );
    expect(events.map((e) => e.eventId), [r'$i1', r'$v', r'$i2']);
    expect(index, 1);
  });

  // AC:RL-windows-video-viewer-playback/4
  for (final supportsVideo in [true, false]) {
    test('тапнутого нет в ленте (supportsVideo=$supportsVideo) — '
        'открывается оно, а не чужая картинка', () {
      final img = media(r'$i', MessageTypes.Image);
      final vid = media(r'$v', MessageTypes.Video);
      final outside = media(r'$out', MessageTypes.Video);
      final tapped = supportsVideo ? outside : vid;
      final (events, index) = viewerEvents(
        [img, vid],
        tapped,
        supportsVideo: supportsVideo,
      );
      expect(events.map((e) => e.eventId), [tapped.eventId]);
      expect(index, 0);
    });
  }

  test('без таймлайна — только тапнутое', () {
    final vid = media(r'$v', MessageTypes.Video);
    final (events, index) = viewerEvents(null, vid, supportsVideo: true);
    expect(events.single.eventId, r'$v');
    expect(index, 0);
  });
}
