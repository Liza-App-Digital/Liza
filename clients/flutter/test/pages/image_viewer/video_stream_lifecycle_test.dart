// ledger:RL-video-stream-progress-and-lifecycle
// guard.render:real-widget
// Настоящий EventVideoPlayer; заменены native backend и texture, не lifecycle.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:media_kit/media_kit.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/image_viewer/carousel_video_controls.dart';
import 'package:liza/pages/image_viewer/video_player.dart';
import 'package:liza/utils/e2ee_media_proxy.dart';
import '../../utils/test_client.dart';

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());

  final commands = <String>[];
  Completer<void>? opening;
  Completer<void>? stopping;
  Object? openFailure;
  bool disposed = false;
  int get plays => commands.where((c) => c == 'play').length;
  int get opens => commands.where((c) => c.startsWith('open:')).length;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    commands.add('open:$play');
    await opening?.future;
    if (openFailure != null) throw openFailure!;
    state = PlayerState(playing: play);
    playingController.add(play);
  }

  @override
  Future<void> stop() async {
    commands.add('stop');
    await stopping?.future;
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> play() async {
    commands.add('play');
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {
    commands.add('volume:$volume');
    state = state.copyWith(volume: volume);
  }

  @override
  Future<void> seek(Duration duration) async {
    commands.add('seek:${duration.inMilliseconds}');
    position(duration);
  }

  void position(Duration value) {
    state = state.copyWith(position: value);
    positionController.add(value);
  }

  void frame() {
    state = state.copyWith(width: 640, duration: const Duration(minutes: 5));
    widthController.add(640);
  }

  void eof() {
    // Порядок NativePlayer real.dart / eof-reached.
    state = state.copyWith(playing: false, completed: true);
    playingController.add(false);
    completedController.add(true);
  }

  void repeatCompleted() {
    completedController.add(false);
    completedController.add(true);
  }

  void fail({bool log = false}) {
    const message = 'Failed to recognize file format';
    if (log) {
      logController.add(
        const PlayerLog(prefix: 'demux', level: 'fatal', text: message),
      );
    } else {
      errorController.add(message);
    }
  }

  // Моделируем native callbacks, уже отправленные через platform channel:
  // они могут доехать после dispose. Закрываем контроллеры лишь в teardown.
  @override
  // ignore: must_call_super
  Future<void> dispose() async {
    commands.add('dispose');
    disposed = true;
  }

  Future<void> closeStreams() => super.dispose();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Client client;
  late Room room;
  late Directory temporary;
  final backends = <_Backend>[];
  final reads = <String>[];
  final writes = <String>[];
  var sequence = 0;
  var cacheDuration = '5';
  var cacheSpeed = '1000000';
  var pausedForCache = 'no';
  Future<String?> Function(Player, String)? readOverride;
  Future<void> Function(Player, String, String)? writeOverride;
  _Backend Function()? createOverride;
  E2eeProxySnapshot? snapshot;
  var downloads = 0;
  var downloadClients = 0;
  var storyEnds = 0;
  Future<http.Response> Function(http.Request)? downloadResponse;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('video-lifecycle-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => temporary.path,
    );
  });

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    await client.abortSync();
    room = Room(id: '!video:example.invalid', client: client);
    await E2eeMediaProxy.instance.ensureStarted();
    backends.clear();
    reads.clear();
    writes.clear();
    cacheDuration = '5';
    cacheSpeed = '1000000';
    pausedForCache = 'no';
    readOverride = null;
    writeOverride = null;
    createOverride = null;
    snapshot = null;
    downloads = 0;
    downloadClients = 0;
    storyEnds = 0;
    downloadResponse = null;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() async {
    for (final backend in backends) {
      await backend.closeStreams();
    }
    await E2eeMediaProxy.instance.stop();
    await client.dispose(closeDatabase: true);
  });

  tearDownAll(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await temporary.delete(recursive: true);
  });

  Event video({bool encrypted = true}) => Event(
    type: EventTypes.Message,
    eventId: '\$lifecycle-${sequence++}',
    senderId: '@alice:example.invalid',
    originServerTs: DateTime(2026, 10, 30),
    room: room,
    content: {
      'msgtype': MessageTypes.Video,
      'body': 'video.mp4',
      if (!encrypted) 'url': 'mxc://example.invalid/video-$sequence',
      if (encrypted)
        'file': {
          'url': 'mxc://example.invalid/video-$sequence',
          'key': {
            'k': base64Url.encode(List.filled(32, 1)),
            'alg': 'A256CTR',
            'kty': 'oct',
            'ext': true,
            'key_ops': ['encrypt', 'decrypt'],
          },
          'iv': base64.encode(List.filled(16, 0)),
          'hashes': {'sha256': base64.encode(List.filled(32, 0))},
          'v': 'v2',
        },
      'info': {'mimetype': 'video/mp4', 'size': 160000000, 'w': 640, 'h': 480},
    },
  );

  Widget app(Event event, {bool active = true, bool story = false}) =>
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: EventVideoPlayer(
            event,
            isActive: active,
            storyMode: story,
            onStoryEnded: () => storyEnds++,
            elapsed: () => binding.clock.now().difference(DateTime(2020)),
            snapshotReader: (id) =>
                snapshot ?? E2eeMediaProxy.instance.snapshot(id),
            playerFactory: () {
              final backend = createOverride?.call() ?? _Backend();
              backends.add(backend);
              return Player(platformPlayer: backend);
            },
            videoSurfaceBuilder: (_, player) => const SizedBox.expand(),
            downloadClientFactory: () {
              downloadClients++;
              return MockClient((request) async {
                downloads++;
                if (downloadResponse != null) return downloadResponse!(request);
                throw const FileSystemException('Управляемая ошибка download');
              });
            },
            propertyReader: (player, property) async {
              reads.add(property);
              if (readOverride != null) return readOverride!(player, property);
              return switch (property) {
                'demuxer-cache-duration' => cacheDuration,
                'cache-speed' => cacheSpeed,
                'paused-for-cache' => pausedForCache,
                'stream-pos' => '0',
                _ => null,
              };
            },
            propertyWriter: (player, property, value) async {
              writes.add('$property=$value');
              await writeOverride?.call(player, property, value);
            },
          ),
        ),
      );

  // Файловый cache и bind localhost работают вне FakeAsync; таймеры самого
  // виджета остаются управляемыми через pump. Нет pumpAndSettle со спиннером.
  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> mount(
    WidgetTester tester,
    Event event, {
    bool story = false,
  }) async {
    // Matrix capabilities AsyncCache и сокеты живут вне FakeAsync. Это
    // инфраструктурные TTL, они не относятся к проверяемым видео-таймерам.
    await tester.runAsync(() async {
      if (event.isAttachmentEncrypted && event.attachmentMxcUrl != null) {
        await E2eeMediaProxy.resolveE2eeDownloadUri(event);
      } else {
        await event.getAttachmentUri();
      }
    });
    await tester.pumpWidget(app(event, story: story));
    for (
      var i = 0;
      i < 20 && find.byType(EventVideoPlayer).evaluate().isEmpty;
      i++
    ) {
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(EventVideoPlayer), findsOneWidget);
    if (!story) {
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    }
    for (
      var i = 0;
      i < 10 && (backends.isEmpty || backends.last.opens == 0);
      i++
    ) {
      await flush(tester);
    }
    expect(backends.last.opens, 1, reason: 'production _start дошёл до open');
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  }

  final error = find.byKey(const Key('video-error-overlay'));

  for (final viaLog in [false, true]) {
    testWidgets(
      'terminal ${viaLog ? 'fatal log' : 'stream.error'} останавливает '
      'звук и monitor',
      (tester) async {
        await mount(tester, video());
        final backend = backends.single;
        backend.frame();
        await tester.pump();
        expect(backend.state.playing, isTrue);
        await tester.pump(const Duration(seconds: 2));
        expect(reads, isNotEmpty);
        backend.fail(log: viaLog);
        await flush(tester);
        // AC:RL-video-stream-progress-and-lifecycle/6
        expect(error, findsOneWidget);
        expect(backend.state.playing, isFalse);
        expect(backend.commands, contains('stop'));
        final count = reads.length;
        await tester.pump(const Duration(seconds: 30));
        expect(reads.length, count, reason: 'terminal отменяет monitor');
        // AC:RL-video-stream-progress-and-lifecycle/16
        expect(
          backends,
          hasLength(1),
          reason: 'runtime E2EE error не открывает fallback',
        );
        expect(downloads, 0);
        expect(downloadClients, 0);
        expect(find.byType(ElevatedButton), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        await unmount(tester);
      },
    );
  }

  testWidgets('late open после terminal не включает autoplay', (tester) async {
    final opening = Completer<void>();
    createOverride = () => _Backend()..opening = opening;
    await mount(tester, video());
    final backend = backends.single;
    backend.fail();
    await tester.pump();
    expect(error, findsOneWidget);
    opening.complete();
    await flush(tester);
    // AC:RL-video-stream-progress-and-lifecycle/6
    // AC:RL-video-stream-progress-and-lifecycle/7
    expect(backend.commands, contains('open:false'));
    expect(backend.plays, 0);
    expect(backend.state.playing, isFalse);
    expect(
      backend.commands.lastIndexOf('stop'),
      greaterThan(backend.commands.indexOf('open:false')),
    );
    expect(error, findsOneWidget);
    await unmount(tester);
  });

  testWidgets('retry ждёт незавершённый open старой попытки', (tester) async {
    final opening = Completer<void>();
    createOverride = () =>
        _Backend()..opening = backends.isEmpty ? opening : null;
    await mount(tester, video());
    final old = backends.single;
    old.fail();
    await tester.pump();
    expect(error, findsOneWidget);
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump(const Duration(seconds: 2));
    // AC:RL-video-stream-progress-and-lifecycle/7
    expect(backends, hasLength(1));
    expect(old.opens, 1);
    expect(old.disposed, isFalse);
    expect(old.plays, 0);

    opening.complete();
    for (
      var i = 0;
      i < 10 && (backends.length < 2 || backends.last.opens == 0);
      i++
    ) {
      await flush(tester);
    }
    expect(backends, hasLength(2));
    final current = backends.last;
    await flush(tester);
    expect(old.disposed, isTrue);
    expect(old.plays, 0, reason: 'late open старой попытки без autoplay');
    expect(current.opens, 1);
    expect(current.plays, 1);
    expect(error, findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(current.state.playing, isTrue);
    expect(
      current.commands,
      isNot(contains('stop')),
      reason: 'cleanup старого open не останавливает новый Player',
    );
    await unmount(tester);
  });

  testWidgets('terminal без retry игнорирует поздние native error и frame', (
    tester,
  ) async {
    await mount(tester, video());
    final backend = backends.single;
    backend.frame();
    await tester.pump(const Duration(seconds: 2));
    final plays = backend.plays;
    final stopping = Completer<void>();
    backend.stopping = stopping;
    backend.fail();
    await tester.pump();
    final readCount = reads.length;
    // Контроллеры ещё живы: события реально отправлены до завершения stop.
    backend.fail(log: true);
    backend.frame();
    backend.position(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 6));
    // AC:RL-video-stream-progress-and-lifecycle/7
    expect(error, findsOneWidget);
    expect(find.byType(CarouselVideoControls), findsNothing);
    expect(backends, hasLength(1));
    expect(backend.plays, plays);
    expect(reads, hasLength(readCount));

    stopping.complete();
    await flush(tester);
    expect(backend.disposed, isTrue);
    expect(backend.state.playing, isFalse);
    // Fake сохраняет native streams до teardown и после dispose.
    backend.fail();
    backend.frame();
    backend.position(const Duration(seconds: 20));
    await tester.pump();
    expect(error, findsOneWidget);
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(backend.state.playing, isFalse);
    expect(backend.plays, plays);
    expect(backends, hasLength(1));
    await unmount(tester);
  });

  testWidgets('retry ждёт stop и объединяет двойной tap', (tester) async {
    await mount(tester, video());
    final old = backends.single;
    old.stopping = Completer<void>();
    old.fail();
    await tester.pump();
    final retry = tester
        .widget<ElevatedButton>(find.byType(ElevatedButton))
        .onPressed!;
    retry();
    retry();
    await tester.pump();
    // AC:RL-video-stream-progress-and-lifecycle/8
    expect(backends, hasLength(1));
    expect(old.opens, 1);
    old.stopping!.complete();
    for (
      var i = 0;
      i < 10 && (backends.length < 2 || backends.last.opens == 0);
      i++
    ) {
      await flush(tester);
    }
    expect(backends, hasLength(2));
    expect(backends.last.opens, 1);
    expect(old.disposed, isTrue);
    expect(error, findsNothing);
    // AC:RL-video-stream-progress-and-lifecycle/7
    old.fail();
    old.frame();
    old.position(const Duration(seconds: 10));
    await tester.pump();
    expect(error, findsNothing);
    expect(
      find.byType(CarouselVideoControls),
      findsNothing,
      reason: 'старый first-frame не снимает гейт новой попытки',
    );
    backends.last.frame();
    await tester.pump();
    expect(find.byType(CarouselVideoControls), findsOneWidget);
    await unmount(tester);
  });

  for (final story in [false, true]) {
    testWidgets('свайп при pending open: story=$story не играет скрыто', (
      tester,
    ) async {
      final opening = Completer<void>();
      createOverride = () => _Backend()..opening = opening;
      final event = video();
      await mount(tester, event, story: story);
      await tester.pumpWidget(app(event, active: false, story: story));
      opening.complete();
      await flush(tester);
      // AC:RL-video-stream-progress-and-lifecycle/9
      expect(backends.single.plays, 0);
      expect(backends.single.state.playing, isFalse);
      if (story) {
        expect(
          backends.single.commands.indexOf('volume:0.0'),
          lessThan(backends.single.commands.indexOf('open:false')),
        );
      }
      await unmount(tester);
    });
  }

  testWidgets('dispose при pending open исключает поздний play', (
    tester,
  ) async {
    final opening = Completer<void>();
    createOverride = () => _Backend()..opening = opening;
    await mount(tester, video());
    final backend = backends.single;
    await unmount(tester);
    opening.complete();
    await flush(tester);
    backend.fail();
    backend.frame();
    await tester.pump();
    // AC:RL-video-stream-progress-and-lifecycle/7
    expect(backend.plays, 0);
    expect(backend.state.playing, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final end in ['terminal', 'retry', 'dispose']) {
    testWidgets('single-flight и late property после $end', (tester) async {
      await mount(tester, video());
      final old = backends.single;
      old.frame();
      await tester.pump();
      final pending = Completer<String?>();
      var active = 0;
      var maxActive = 0;
      readOverride = (player, property) async {
        if (!identical(player.platform, old)) return null;
        active++;
        if (active > maxActive) maxActive = active;
        try {
          return await pending.future;
        } finally {
          active--;
        }
      };
      await tester.pump(const Duration(seconds: 2));
      final startedReads = reads.length;
      await tester.pump(const Duration(seconds: 8));
      // AC:RL-video-stream-progress-and-lifecycle/10
      expect(maxActive, 3, reason: 'один batch из трёх свойств');
      expect(
        reads.length,
        startedReads,
        reason: 'timeout не размножает реальные batch',
      );
      if (end == 'dispose') {
        await unmount(tester);
      } else {
        old.fail();
        await tester.pump();
        expect(error, findsOneWidget);
        if (end == 'retry') {
          await tester.tap(find.byType(ElevatedButton));
          await flush(tester);
          await flush(tester);
        }
      }
      final writeCount = writes.length;
      pending.complete('25');
      await tester.pump();
      // AC:RL-video-stream-progress-and-lifecycle/7
      expect(
        writes.length,
        writeCount,
        reason: 'старый batch не настраивает новый engine',
      );
      expect(tester.takeException(), isNull);
      if (end == 'terminal') expect(error, findsOneWidget);
      if (end == 'retry') expect(error, findsNothing);
      await unmount(tester);
    });
  }

  for (final progress in ['cache-speed', 'cache-duration', 'playback']) {
    testWidgets('non-E2EE $progress сохраняет живой поток 240 секунд', (
      tester,
    ) async {
      await mount(tester, video(encrypted: false));
      cacheSpeed = progress == 'cache-speed' ? '1000000' : '0';
      pausedForCache = 'yes';
      for (var i = 0; i < 120; i++) {
        if (progress == 'cache-duration') cacheDuration = '${i + 1}';
        if (progress == 'playback') {
          backends.single.position(Duration(seconds: i + 1));
        }
        await tester.pump(const Duration(seconds: 2));
      }
      // AC:RL-video-stream-progress-and-lifecycle/2
      expect(error, findsNothing);
      expect(backends.single.commands, isNot(contains('stop')));
      expect(backends.single.opens, 1);
      await unmount(tester);
    });
  }

  for (final inactive in ['suspended', 'hidden', 'manual-pause']) {
    testWidgets('$inactive 180 секунд не расходует idle budget', (
      tester,
    ) async {
      final event = video();
      await mount(tester, event);
      final backend = backends.single;
      backend.frame();
      await tester.pump();
      cacheSpeed = '0';
      cacheDuration = '0';
      if (inactive == 'suspended') {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      } else if (inactive == 'hidden') {
        await tester.pumpWidget(app(event, active: false));
      } else {
        await backend.pause();
      }
      await tester.pump();
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      // AC:RL-video-stream-progress-and-lifecycle/5
      expect(error, findsNothing);
      expect(backend.commands, isNot(contains('stop')));
      if (inactive == 'suspended') {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      } else if (inactive == 'hidden') {
        await tester.pumpWidget(app(event));
        // Обычный viewer сохраняет паузу после свайпа; возврат сам не Play.
        expect(backend.state.playing, isFalse);
        await backend.play();
      } else {
        await backend.play();
      }
      await tester.pump();
      expect(
        backend.state.playing,
        isTrue,
        reason: 'resume действительно продолжает просмотр',
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(
        error,
        findsNothing,
        reason: 'после возврата начинается новое окно',
      );
      await unmount(tester);
    });
  }

  testWidgets(
    'недоступные свойства и неподвижное видео завершаются за 67 секунд',
    (tester) async {
      final logStart = Logs().outputEvents.length;
      readOverride = (_, _) async => null;
      await mount(tester, video());
      for (var i = 0; i < 67; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      // AC:RL-video-stream-progress-and-lifecycle/4
      expect(error, findsOneWidget);
      expect(backends.single.state.playing, isFalse);
      final failures = Logs().outputEvents
          .skip(logStart)
          .where((entry) => entry.title.startsWith('Unable to play video:'))
          .map((entry) => entry.title)
          .toList();
      expect(failures, hasLength(1));
      expect(failures.single, contains('playback unresponsive (rate-unknown)'));
      expect(failures.single, isNot(contains('network-stall')));
      // AC:RL-video-stream-progress-and-lifecycle/16
      expect(backends.single.opens, 1);
      expect(backends, hasLength(1));
      await unmount(tester);
    },
  );

  for (final chunkInterval in [2, 59]) {
    testWidgets('E2EE progress каждые $chunkInterval с жив 240 секунд', (
      tester,
    ) async {
      var received = 0;
      snapshot = const E2eeProxySnapshot(
        receivedBytes: 0,
        activeRequests: 1,
        phase: E2eeProxyPhase.streaming,
      );
      cacheSpeed = '0';
      cacheDuration = '0';
      pausedForCache = 'yes';
      await mount(tester, video());
      for (var second = 1; second <= 240; second++) {
        if (second % chunkInterval == 0) {
          received += 4096;
          snapshot = E2eeProxySnapshot(
            receivedBytes: received,
            activeRequests: 1,
            phase: E2eeProxyPhase.streaming,
          );
        }
        await tester.pump(const Duration(seconds: 1));
        // AC:RL-video-stream-progress-and-lifecycle/1
        expect(
          error,
          findsNothing,
          reason: 'секунда $second, upstream=$received',
        );
      }
      expect(backends.single.state.position, Duration.zero);
      expect(backends.single.commands, isNot(contains('stop')));
      expect(backends.single.opens, 1);
      await unmount(tester);
    });
  }

  testWidgets('E2EE без прогресса завершается не позже 122 секунд', (
    tester,
  ) async {
    snapshot = const E2eeProxySnapshot(
      receivedBytes: 0,
      activeRequests: 1,
      phase: E2eeProxyPhase.retrying,
    );
    cacheSpeed = '0';
    cacheDuration = '0';
    pausedForCache = 'yes';
    await mount(tester, video());
    for (var second = 1; second <= 118; second++) {
      await tester.pump(const Duration(seconds: 1));
    }
    // AC:RL-video-stream-progress-and-lifecycle/3
    expect(
      error,
      findsNothing,
      reason: 'не обрываем законный proxy reconnect на 60 с',
    );
    for (var second = 119; second <= 122; second++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(error, findsOneWidget);
    expect(backends.single.state.playing, isFalse);
    // AC:RL-video-stream-progress-and-lifecycle/16
    expect(backends, hasLength(1));
    expect(downloads, 0, reason: 'runtime stall не начал HTTP full-download');
    expect(
      backends.single.opens,
      1,
      reason: 'runtime stall не запускает full-download',
    );
    await unmount(tester);
  });

  testWidgets('rebuffer считает переходы после кадра, а не тики', (
    tester,
  ) async {
    await mount(tester, video());
    final state = tester.state<EventVideoPlayerState>(
      find.byType(EventVideoPlayer),
    );
    pausedForCache = 'yes';
    for (var tick = 0; tick < 6; tick++) {
      await tester.pump(const Duration(seconds: 2));
    }
    expect(state.rebufferEpisodes, 0, reason: 'startup не rebuffer');
    pausedForCache = 'no';
    backends.single.frame();
    await tester.pump(const Duration(seconds: 2));
    pausedForCache = 'yes';
    for (var tick = 0; tick < 6; tick++) {
      await tester.pump(const Duration(seconds: 2));
    }
    // AC:RL-video-stream-progress-and-lifecycle/15
    expect(state.rebufferEpisodes, 1);
    expect(state.rebufferReported, isFalse);
    for (var episode = 0; episode < 2; episode++) {
      pausedForCache = 'no';
      await tester.pump(const Duration(seconds: 2));
      pausedForCache = 'yes';
      await tester.pump(const Duration(seconds: 2));
    }
    expect(state.rebufferEpisodes, 3);
    expect(state.rebufferReported, isTrue);
    pausedForCache = 'no';
    await tester.pump(const Duration(seconds: 2));
    pausedForCache = 'yes';
    await tester.pump(const Duration(seconds: 2));
    expect(
      state.rebufferEpisodes,
      3,
      reason: 'после первого сигнала защёлка закрыта',
    );
    await unmount(tester);
  });

  for (final result in ['success', 'failure', 'late-dispose']) {
    testWidgets('non-E2EE swap: $result', (tester) async {
      final response = Completer<http.Response>();
      downloadResponse = (_) => response.future;
      await mount(tester, video(encrypted: false));
      final old = backends.single;
      old.frame();
      await tester.pump();
      expect(old.state.playing, isTrue);
      old.fail();
      for (var i = 0; i < 20 && downloads == 0; i++) {
        await flush(tester);
      }
      expect(downloads, 1);
      expect(old.state.playing, isFalse);
      expect(old.disposed, isTrue);
      final local = backends.last;
      expect(local.opens, 0, reason: 'open ждёт полного файла');
      if (result == 'late-dispose') await unmount(tester);
      if (result == 'failure') {
        response.completeError(const FileSystemException('download failed'));
      } else {
        response.complete(
          http.Response.bytes(List.generate(32, (i) => i), 200),
        );
      }
      for (
        var i = 0;
        i < 20 && local.opens == 0 && error.evaluate().isEmpty;
        i++
      ) {
        await flush(tester);
      }
      if (result == 'success') {
        // AC:RL-video-stream-progress-and-lifecycle/16
        expect(local.opens, 1);
        expect(local.state.playing, isTrue);
        expect(error, findsNothing);
      } else if (result == 'failure') {
        // AC:RL-video-stream-progress-and-lifecycle/6
        expect(error, findsOneWidget);
        expect(local.state.playing, isFalse);
        expect(local.commands, contains('stop'));
      } else {
        // AC:RL-video-stream-progress-and-lifecycle/7
        expect(local.opens, 0);
        expect(local.plays, 0);
        expect(local.state.playing, isFalse);
        expect(tester.takeException(), isNull);
      }
      await unmount(tester);
    });
  }

  testWidgets(
    'E2EE initial open failure сохраняет fallback и terminal при его ошибке',
    (tester) async {
      createOverride = () => _Backend()
        ..openFailure = backends.isEmpty
            ? StateError('initial open failed')
            : null;
      await mount(tester, video());
      for (var i = 0; i < 20 && error.evaluate().isEmpty; i++) {
        await flush(tester);
      }
      // AC:RL-video-stream-progress-and-lifecycle/6
      // AC:RL-video-stream-progress-and-lifecycle/16
      expect(
        downloadClients,
        1,
        reason: 'существующий initial fallback не удалён',
      );
      expect(downloads, 0, reason: 'SDK без native crypto отказывает до HTTP');
      expect(error, findsOneWidget);
      expect(backends, hasLength(2));
      for (final backend in backends) {
        expect(backend.state.playing, isFalse);
        expect(backend.commands, contains('stop'));
      }
      await unmount(tester);
    },
  );

  testWidgets('E2EE initial fallback играет доступные локальные байты', (
    tester,
  ) async {
    final event = video();
    (event.content['file'] as Map).remove('url');
    room.sendingFilePlaceholders[event.eventId] = MatrixFile(
      bytes: Uint8List.fromList(List.generate(32, (i) => i)),
      name: 'initial.mp4',
    );
    await mount(tester, event);
    // AC:RL-video-stream-progress-and-lifecycle/16
    expect(backends, hasLength(2));
    expect(backends.first.disposed, isTrue);
    expect(backends.last.state.playing, isTrue);
    expect(backends.last.commands, contains('open:false'));
    expect(error, findsNothing);
    await unmount(tester);
  });

  testWidgets('новый local Player fatal во время pending open завершает swap', (
    tester,
  ) async {
    final localOpening = Completer<void>();
    createOverride = () =>
        _Backend()..opening = backends.isEmpty ? null : localOpening;
    downloadResponse = (_) async =>
        http.Response.bytes(List.generate(32, (i) => i), 200);
    await mount(tester, video(encrypted: false));
    backends.first.fail();
    for (
      var i = 0;
      i < 20 && (backends.length < 2 || backends.last.opens == 0);
      i++
    ) {
      await flush(tester);
    }
    expect(backends, hasLength(2));
    final local = backends.last;
    expect(local.opens, 1);
    local.fail();
    await tester.pump();
    // AC:RL-video-stream-progress-and-lifecycle/6
    expect(
      error,
      findsOneWidget,
      reason: 'фатальная ошибка нового engine не является шумом старого',
    );
    localOpening.complete();
    await flush(tester);
    expect(local.state.playing, isFalse);
    expect(local.plays, 0);
    expect(local.commands, contains('stop'));
    expect(downloads, 1, reason: 'никакого рекурсивного fallback');
    await unmount(tester);
  });

  for (final active in [true, false]) {
    testWidgets(
      'story EOF playing=false перед completed=true, active=$active',
      (tester) async {
        final event = video();
        await mount(tester, event, story: true);
        final backend = backends.single;
        if (!active) {
          await tester.pumpWidget(app(event, story: true, active: false));
        }
        backend.eof();
        await tester.pump();
        expect(
          storyEnds,
          active ? 1 : 0,
          reason: 'порядок событий media_kit EOF не является ручной паузой',
        );
        backend.repeatCompleted();
        await tester.pump();
        expect(storyEnds, active ? 1 : 0, reason: 'один переход на историю');
        await unmount(tester);
      },
    );
  }

  testWidgets('ручная пауза переживает полный background lifecycle', (
    tester,
  ) async {
    await mount(tester, video());
    final backend = backends.single;
    backend.frame();
    await tester.pump();
    await backend.pause();
    await tester.pump();
    final plays = backend.plays;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    // AC:RL-video-stream-progress-and-lifecycle/5
    expect(backend.state.playing, isFalse);
    expect(backend.plays, plays, reason: 'resume не отменяет ручную паузу');
    await unmount(tester);
  });

  testWidgets('story terminal игнорирует поздний EOF', (tester) async {
    await mount(tester, video(), story: true);
    backends.single.fail();
    await flush(tester);
    backends.single.eof();
    await tester.pump();
    // AC:RL-video-stream-progress-and-lifecycle/7
    expect(error, findsOneWidget);
    expect(storyEnds, 0);
    await unmount(tester);
  });

  testWidgets(
    'open завершился в фоне: play ждёт resume и сохраняет намерение',
    (tester) async {
      final opening = Completer<void>();
      createOverride = () => _Backend()..opening = opening;
      await mount(tester, video());
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      opening.complete();
      await flush(tester);
      // AC:RL-video-stream-progress-and-lifecycle/7
      expect(backends.single.plays, 0);
      expect(backends.single.state.playing, isFalse);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      expect(backends.single.plays, 1);
      expect(backends.single.state.playing, isTrue);
      await unmount(tester);
    },
  );

  for (final retry in [false, true]) {
    testWidgets(
      'late download после terminal, retry=$retry не меняет текущий экран',
      (tester) async {
        final response = Completer<http.Response>();
        downloadResponse = (_) => response.future;
        await mount(tester, video(encrypted: false));
        backends.first.fail();
        for (var i = 0; i < 20 && downloads == 0; i++) {
          await flush(tester);
        }
        expect(downloads, 1);
        final retired = backends.last;
        retired.fail();
        await flush(tester);
        expect(error, findsOneWidget);
        if (retry) {
          await tester.tap(find.byType(ElevatedButton));
          for (
            var i = 0;
            i < 20 && (backends.length < 3 || backends.last.opens == 0);
            i++
          ) {
            await flush(tester);
          }
          expect(backends, hasLength(3));
          expect(backends.last.state.playing, isTrue);
        }
        response.complete(
          http.Response.bytes(List.generate(32, (i) => i), 200),
        );
        for (var i = 0; i < 5; i++) {
          await flush(tester);
        }
        // AC:RL-video-stream-progress-and-lifecycle/7
        expect(retired.opens, 0);
        expect(retired.state.playing, isFalse);
        expect(error, retry ? findsNothing : findsOneWidget);
        if (retry) expect(backends.last.opens, 1);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      },
    );
  }

  testWidgets('late playing echo скрытого viewer не отменяет паузу', (
    tester,
  ) async {
    final event = video();
    await mount(tester, event);
    final backend = backends.single;
    backend.frame();
    await tester.pump();
    await tester.pumpWidget(app(event, active: false));
    // Эхо ранее отправленной play-команды, затем реальная pause-команда.
    await backend.play();
    await tester.pump();
    await backend.pause();
    await tester.pump();
    await tester.pumpWidget(app(event));
    cacheDuration = '0';
    cacheSpeed = '0';
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    // AC:RL-video-stream-progress-and-lifecycle/5
    // AC:RL-video-stream-progress-and-lifecycle/7
    expect(backend.state.playing, isFalse);
    expect(error, findsNothing);
    await backend.play();
    await tester.pump();
    for (var i = 0; i < 67; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(
      error,
      findsOneWidget,
      reason: 'после настоящего Play monitor снова работает',
    );
    await unmount(tester);
  });

  testWidgets(
    'адаптация cache сохраняет low/high policy и не пишет её каждый тик',
    (tester) async {
      await mount(tester, video(encrypted: false));
      writes.clear();
      cacheDuration = '1';
      await tester.pump(const Duration(seconds: 2));
      expect(
        writes,
        containsAllInOrder(['cache-secs=120', 'cache-pause-wait=5']),
      );
      final lowCount = writes.length;
      await tester.pump(const Duration(seconds: 2));
      expect(writes.length, lowCount);
      cacheDuration = '20';
      await tester.pump(const Duration(seconds: 2));
      expect(writes.skip(lowCount), ['cache-secs=30', 'cache-pause-wait=2']);
      expect(error, findsNothing);
      await unmount(tester);
    },
  );

  testWidgets(
    'pending cache write не размножается и не продолжает старую policy после retry',
    (tester) async {
      await mount(tester, video());
      final old = backends.single;
      final pending = Completer<void>();
      var oldPolicyWrites = 0;
      writeOverride = (player, property, value) async {
        if (identical(player.platform, old) && property == 'cache-secs') {
          oldPolicyWrites++;
          await pending.future;
        }
      };
      cacheDuration = '1';
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(oldPolicyWrites, 1);
      expect(
        error,
        findsNothing,
        reason: 'optional cache write failure не playback error',
      );
      old.fail();
      await flush(tester);
      await tester.tap(find.byType(ElevatedButton));
      for (
        var i = 0;
        i < 20 && (backends.length < 2 || backends.last.opens == 0);
        i++
      ) {
        await flush(tester);
      }
      expect(backends, hasLength(2));
      final writeCount = writes.length;
      pending.complete();
      await tester.pump();
      // AC:RL-video-stream-progress-and-lifecycle/7
      expect(
        writes.length,
        writeCount,
        reason: 'не отправляет второе свойство старой policy',
      );
      expect(backends.last.state.playing, isTrue);
      expect(error, findsNothing);
      await unmount(tester);
    },
  );
}
