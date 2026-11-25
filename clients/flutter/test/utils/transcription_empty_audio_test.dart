// Страж «расшифровка битого голосового говорит „в нём нет звука“, а не
// „ошибка сервера“» (RL-voice-empty-recording-guard, AC-10).
//
// Саша, 24.11: «Транскрибацию тоже не дает сделать "ошибка сервера"». transcribe
// теперь отвечает на пустое аудио 422 `audio_empty`. Рендерится РЕАЛЬНЫЙ
// `AudioPlayerWidget`; сеть подменена `debugFetch`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/audio_player.dart';
import 'package:liza/utils/transcription_service.dart';
import 'package:liza/widgets/matrix.dart';

import 'test_client.dart';

// Страж реестра регрессии: ledger:RL-voice-empty-recording-guard
void main() {
  late Client client;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    client.rooms.clear();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  group('маппинг ответа transcribe', () {
    test('∀ 422 {audio_empty, bad_audio} → emptyAudio; 500/503/200 → не он — '
        'AC:RL-voice-empty-recording-guard/10', () {
      for (final code in ['audio_empty', 'bad_audio']) {
        final e = TranscriptionService.rejectedInput(
          http.Response('{"error":"$code"}', 422),
        );
        expect(e?.kind, TranscriptionErrorKind.emptyAudio, reason: code);
        expect(e?.statusCode, 422);
      }
      for (final status in [200, 500, 503]) {
        expect(
          TranscriptionService.rejectedInput(
            http.Response('{"error":"internal_error"}', status),
          ),
          isNull,
          reason: '$status',
        );
      }
    });
  });

  testWidgets('тап «Тт» по пустому голосовому → текст «нет звука», а не '
      '«ошибка сервера» — AC:RL-voice-empty-recording-guard/10', (
    tester,
  ) async {
    final room = Room(id: '!g:example.invalid', client: client);
    final store = await SharedPreferences.getInstance();
    final event = Event(
      eventId: r'$empty',
      senderId: '@sasha:example.invalid',
      originServerTs: DateTime.now(),
      type: EventTypes.Message,
      content: {
        'msgtype': MessageTypes.Audio,
        'body': 'recording.m4a',
        'url': 'mxc://x/empty',
        'org.matrix.msc3245.voice': <String, dynamic>{},
        'info': {'duration': 48900, 'size': 16726, 'mimetype': 'audio/mp4'},
      },
      room: room,
    );

    late MatrixState matrix;
    late L10n l10n;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        home: Matrix(
          clients: [client],
          store: store,
          child: Builder(
            builder: (context) {
              matrix = Matrix.of(context);
              l10n = L10n.of(context);
              return Scaffold(
                body: SizedBox(
                  width: 320,
                  child: AudioPlayerWidget(
                    event,
                    color: Colors.black,
                    linkColor: Colors.blue,
                    fontSize: 14,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    matrix.transcriptionService.debugFetch = (_) async =>
        throw TranscriptionService.rejectedInput(
          http.Response('{"error":"audio_empty"}', 422),
        )!;

    await tester.tap(find.byIcon(Icons.text_fields_outlined));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text(l10n.transcriptionEmptyAudio), findsOneWidget);
    expect(find.text(l10n.transcriptionServerError), findsNothing);
  });
}
