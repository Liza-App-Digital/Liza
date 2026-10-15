// Страж «в личке с ИИ-ботом текст голосового появляется в чате сам»
// (RL-ai-dm-voice-auto-transcript).
//
// Роман, 14.10: «…звуковуха уже не нужна боту… То есть в чате должен текст
// появиться». Рендерится РЕАЛЬНЫЙ `AudioPlayerWidget`; сетевая часть сервиса
// расшифровки подменена `debugFetch` (счётчик вызовов = число HTTP-запросов).
//
// Red-proof (мутации, 2026-10-14): без автозапуска в `_restoreTranscription` —
// AC-1/AC-2 красные; без `cachedText` в пересозданном пузыре — AC-5; без
// `_autoFailed` — AC-6; без порога свежести — AC-3.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/pages/chat/events/audio_player.dart';
import 'package:liza/utils/transcription_service.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/test_client.dart';

// Страж реестра регрессии: ledger:RL-ai-dm-voice-auto-transcript
void main() {
  late Client client;
  late Room room;
  late SharedPreferences store;

  const bot = '@agent:bots.liza.ru';
  const human = '@friend:example.invalid';
  const transcript = 'Ну то есть если бы я наговорил боту, он бы понял';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    client.rooms.clear();
    room = Room(id: '!dm:example.invalid', client: client);
    store = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  void setDirect(String? userId, [String roomId = '!dm:example.invalid']) {
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        if (userId != null) userId: [roomId],
      },
    );
  }

  Event audio(
    String id, {
    bool voice = true,
    Duration age = const Duration(minutes: 1),
    EventStatus status = EventStatus.synced,
    Room? inRoom,
  }) => Event(
    eventId: id,
    senderId: '@me:example.invalid',
    originServerTs: DateTime.now().subtract(age),
    type: EventTypes.Message,
    content: {
      'msgtype': MessageTypes.Audio,
      'body': 'voice.ogg',
      'url': 'mxc://x/$id',
      if (voice) 'org.matrix.msc3245.voice': <String, dynamic>{},
      'info': {'duration': 8000, 'size': 4200, 'mimetype': 'audio/ogg'},
    },
    room: inRoom ?? room,
    status: status,
  );

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Дерево с Matrix; пузыри показываются ПОСЛЕ подмены сети сервиса.
  Future<({MatrixState matrix, ValueNotifier<List<Event>> shown, List<String> calls})>
  pumpChat(
    WidgetTester tester, {
    Future<String> Function(Event e)? fetch,
    bool autoGate = true,
  }) async {
    late MatrixState matrix;
    final shown = ValueNotifier<List<Event>>([]);
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Matrix(
          clients: [client],
          store: store,
          child: Builder(
            builder: (context) {
              matrix = Matrix.of(context);
              return Scaffold(
                body: ValueListenableBuilder<List<Event>>(
                  valueListenable: shown,
                  builder: (context, events, _) => ListView(
                    children: [
                      for (final e in events)
                        SizedBox(
                          width: 320,
                          child: AudioPlayerWidget(
                            e,
                            key: ValueKey(e.eventId),
                            color: Colors.black,
                            linkColor: Colors.blue,
                            fontSize: 14,
                            autoTranscribe:
                                autoGate && isAiDirectChat(context, e.room),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await drain(tester);
    matrix.transcriptionService.debugFetch =
        fetch ??
        (e) async {
          calls.add(e.eventId);
          return '$transcript (${e.eventId})';
        };
    if (fetch != null) {
      final inner = fetch;
      matrix.transcriptionService.debugFetch = (e) {
        calls.add(e.eventId);
        return inner(e);
      };
    }
    return (matrix: matrix, shown: shown, calls: calls);
  }

  group('гейт комнаты', () {
    testWidgets(
      'AC-1: ∀ {личка с ботом → 1 вызов; с человеком → 0; группа → 0; '
      '@support → 0} — AC:RL-ai-dm-voice-auto-transcript/1',
      (tester) async {
        final cases = <String?, int>{
          bot: 1,
          '@liza:bots.liza.ru': 1,
          human: 0,
          null: 0, // не личка (группа)
          '@support:bots.liza.ru': 0,
        };
        for (final entry in cases.entries) {
          setDirect(entry.key);
          final chat = await pumpChat(tester);
          chat.shown.value = [audio('\$v-${entry.key}')];
          await drain(tester);
          expect(
            chat.calls.length,
            entry.value,
            reason: 'собеседник ${entry.key}',
          );
          await tester.pumpWidget(const SizedBox());
          await drain(tester);
        }
      },
    );

    testWidgets(
      'AC-1: аудиофайл без voice-флага в личке с ботом не расшифровывается — '
      'AC:RL-ai-dm-voice-auto-transcript/1',
      (tester) async {
        setDirect(bot);
        final chat = await pumpChat(tester);
        chat.shown.value = [audio('\$song', voice: false)];
        await drain(tester);
        expect(chat.calls, isEmpty);
      },
    );
  });

  testWidgets(
    'AC-2: три голосовых подряд в личке с ботом — под КАЖДЫМ пузырём текст '
    'без тапа, плеер на месте — AC:RL-ai-dm-voice-auto-transcript/2',
    (tester) async {
      setDirect(bot);
      final chat = await pumpChat(tester);
      chat.shown.value = [audio('\$a'), audio('\$b'), audio('\$c')];
      await drain(tester);
      for (final id in ['\$a', '\$b', '\$c']) {
        expect(find.text('$transcript ($id)'), findsOneWidget, reason: id);
      }
      expect(find.byType(AudioPlayerWidget), findsNWidgets(3));
      expect(find.byIcon(Icons.play_arrow_outlined), findsNWidgets(3));
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'AC-3: ∀ {старше 24 ч → 0; локальное эхо → 0; свежее → 1} — '
    'AC:RL-ai-dm-voice-auto-transcript/3',
    (tester) async {
      setDirect(bot);
      final chat = await pumpChat(tester);
      chat.shown.value = [
        audio('\$old', age: const Duration(hours: 25)),
        audio('\$echo', status: EventStatus.sending),
        audio('\$fresh'),
      ];
      await drain(tester);
      expect(chat.calls, ['\$fresh']);
    },
  );

  testWidgets(
    'AC-4: в чате с человеком — по-прежнему по ручной 🎤 — '
    'AC:RL-ai-dm-voice-auto-transcript/4',
    (tester) async {
      setDirect(human);
      final chat = await pumpChat(tester);
      chat.shown.value = [audio('\$h')];
      await drain(tester);
      expect(chat.calls, isEmpty);
      expect(find.byIcon(Icons.text_fields_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.text_fields_outlined));
      await drain(tester);
      expect(chat.calls, ['\$h']);
      expect(find.text('$transcript (\$h)'), findsOneWidget);
    },
  );

  testWidgets(
    'AC-5: пересозданный пузырь (скролл на desktop/Web) — текст в ПЕРВОМ '
    'кадре, без повторного запроса — AC:RL-ai-dm-voice-auto-transcript/5',
    (tester) async {
      setDirect(bot);
      final chat = await pumpChat(tester);
      final e = audio('\$re');
      chat.shown.value = [e];
      await drain(tester);
      chat.shown.value = [];
      await tester.pump();
      chat.shown.value = [e];
      await tester.pump(); // один кадр — без ожидания
      expect(find.text('$transcript (\$re)'), findsOneWidget);
      await drain(tester);
      expect(chat.calls, ['\$re']);
    },
  );

  testWidgets(
    'AC-6: ∀ ошибок {429, 503, сеть} — без SnackBar, 🎤 доступна, повтора '
    'нет — AC:RL-ai-dm-voice-auto-transcript/6',
    (tester) async {
      setDirect(bot);
      final errors = [
        const TranscriptionException(
          TranscriptionErrorKind.server,
          '429',
          statusCode: 429,
        ),
        const TranscriptionException(
          TranscriptionErrorKind.serviceBusy,
          'busy',
          statusCode: 503,
        ),
        const TranscriptionException(TranscriptionErrorKind.network, 'net'),
      ];
      var i = 0;
      final chat = await pumpChat(
        tester,
        fetch: (e) async => throw errors[i++ % errors.length],
      );
      final events = [audio('\$e1'), audio('\$e2'), audio('\$e3')];
      chat.shown.value = events;
      await drain(tester);
      expect(chat.calls.length, 3);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byIcon(Icons.text_fields_outlined), findsNWidgets(3));

      // Перестроение пузырей (скролл) не перезапускает проваленное.
      chat.shown.value = [];
      await tester.pump();
      chat.shown.value = events;
      await drain(tester);
      expect(chat.calls.length, 3);
    },
  );

  test(
    'AC-7: очередь авто-расшифровки — по одному и не больше 4 за окно — '
    'AC:RL-ai-dm-voice-auto-transcript/7',
    () async {
      final service = TranscriptionService(client)
        ..autoWindow = const Duration(milliseconds: 300);
      var inFlight = 0;
      var maxInFlight = 0;
      final starts = <DateTime>[];
      service.debugFetch = (e) async {
        starts.add(DateTime.now());
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return e.eventId;
      };
      final results = await Future.wait([
        for (var n = 0; n < 6; n++) service.autoTranscribe(audio('\$q$n')),
      ]);
      expect(results, [for (var n = 0; n < 6; n++) '\$q$n']);
      expect(maxInFlight, 1);
      // Пятый ждал, пока освободится окно.
      expect(
        starts[4].difference(starts[0]),
        greaterThanOrEqualTo(const Duration(milliseconds: 290)),
      );
      // Повтор того же события — из кэша, без запроса.
      await service.autoTranscribe(audio('\$q0'));
      expect(starts.length, 6);
    },
  );

  test(
    'AC-8: ручная 🎤 и авто для одного события — один запрос — '
    'AC:RL-ai-dm-voice-auto-transcript/8',
    () async {
      final service = TranscriptionService(client);
      final gate = Completer<void>();
      var calls = 0;
      service.debugFetch = (e) async {
        calls++;
        await gate.future;
        return 'текст';
      };
      final e = audio('\$same');
      final auto = service.autoTranscribe(e);
      await Future<void>.delayed(Duration.zero);
      final manual = service.transcribe(e);
      gate.complete();
      expect(await auto, 'текст');
      expect(await manual, 'текст');
      expect(calls, 1);
    },
  );
}
