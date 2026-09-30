// Голосовые на Web (заявка №44) и Windows (2026-09-29): где виден микрофон,
// каким кодеком пишем, с каким mimetype уходит событие и что бывает, если
// запись не дала файла или не стартовала. kIsWeb/Platform.isWindows на VM не
// подделать — эти ветки проверяются через чистые функции и параметр модели.
//
// ledger:RL-web-voice-record

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/recording_view_model.dart';
import 'package:liza/utils/voice_recording_codec.dart';
import 'package:liza/utils/voice_recording_guard.dart';
import 'test_client.dart';

class _FakeRecorder implements AudioRecorder {
  _FakeRecorder({this.stopPath});

  final String? stopPath;
  int disposeCalls = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {}

  @override
  Future<String?> stop() async => stopPath;

  @override
  Future<void> cancel() async {}

  @override
  Future<Amplitude> getAmplitude() async => Amplitude(current: -30, max: -30);

  @override
  Future<void> dispose() async => disposeCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingStartRecorder extends _FakeRecorder {
  RecordConfig? config;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    this.config = config;
    throw Exception('HRESULT 0x80070005');
  }
}

class _PendingPermissionRecorder extends _FakeRecorder {
  final permission = Completer<bool>();

  @override
  Future<bool> hasPermission() => permission.future;
}

class _FakeWakelock extends WakelockPlusPlatformInterface
    with MockPlatformInterfaceMixin {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async => '/tmp';
}

void main() {
  group('canRecordVoice', () {
    test('AC-1: микрофон везде, кроме Linux', () {
      // AC:RL-web-voice-record/1
      bool can({
        bool web = false,
        bool mobile = false,
        bool macOS = false,
        bool windows = false,
      }) => canRecordVoice(
        isWeb: web,
        isMobile: mobile,
        isMacOS: macOS,
        isWindows: windows,
      );
      expect(can(web: true), isTrue, reason: 'web');
      expect(can(windows: true), isTrue, reason: 'windows');
      expect(can(mobile: true), isTrue, reason: 'mobile');
      expect(can(macOS: true), isTrue, reason: 'macOS');
      expect(can(), isFalse, reason: 'linux');
    });
  });

  group('resolveVoiceCodec', () {
    // (платформа, ожидаемая частота AAC): Web берёт частоту из настроек,
    // Windows — фиксированные 44,1 кГц под AAC-энкодер Media Foundation.
    const webLike = [(false, null), (true, windowsAacSampleRate)];

    test('AC-2: Web и Windows — AAC, если он есть, иначе WAV 16 кГц', () async {
      // AC:RL-web-voice-record/2
      for (final (isWindows, aacRate) in webLike) {
        final platform = isWindows ? 'windows' : 'web';
        Future<VoiceCodec> resolve(Set<AudioEncoder> supported) =>
            resolveVoiceCodec(
              isWeb: !isWindows,
              isIOS: false,
              isWindows: isWindows,
              supports: (e) async => supported.contains(e),
            );

        final aac = await resolve({AudioEncoder.aacLc});
        expect(
          (aac.encoder, aac.sampleRate),
          (AudioEncoder.aacLc, aacRate),
          reason: '$platform: AAC есть',
        );

        final none = await resolve({});
        expect(
          (none.encoder, none.sampleRate),
          (AudioEncoder.wav, 16000),
          reason: '$platform: AAC нет',
        );

        // Firefox / Windows с Opus-MFT: opus есть, AAC нет — всё равно WAV.
        final opusOnly = await resolve({AudioEncoder.opus});
        expect(
          (opusOnly.encoder, opusOnly.sampleRate),
          (AudioEncoder.wav, 16000),
          reason: '$platform: только opus',
        );
      }
    });

    test(
      'AC-13: Windows никогда не пишет opus, даже если плагин его заявил',
      () async {
        // AC:RL-web-voice-record/13
        final codec = await resolveVoiceCodec(
          isWeb: false,
          isIOS: false,
          isWindows: true,
          supports: (e) async => true,
        );
        expect(codec.encoder, AudioEncoder.aacLc);
        expect(codec.sampleRate, windowsAacSampleRate);
      },
    );

    test('AC-3: натив не изменился ∀ {iOS, opus есть, opus нет}', () async {
      // AC:RL-web-voice-record/3
      final ios = await resolveVoiceCodec(
        isWeb: false,
        isIOS: true,
        isWindows: false,
        supports: (e) async => true,
      );
      expect((ios.encoder, ios.sampleRate), (AudioEncoder.aacLc, null));

      final opus = await resolveVoiceCodec(
        isWeb: false,
        isIOS: false,
        isWindows: false,
        supports: (e) async => e == AudioEncoder.opus,
      );
      expect((opus.encoder, opus.sampleRate), (AudioEncoder.opus, null));

      final noOpus = await resolveVoiceCodec(
        isWeb: false,
        isIOS: false,
        isWindows: false,
        supports: (e) async => false,
      );
      expect((noOpus.encoder, noOpus.sampleRate), (AudioEncoder.aacLc, null));
    });
  });

  group('voiceMimeForFileName', () {
    test(
      'AC-4: Web и Windows — audio/mp4 и audio/wav, остальной натив — null',
      () {
        // AC:RL-web-voice-record/4
        for (final (isWeb, isWindows) in [(true, false), (false, true)]) {
          String? mime(String name) =>
              voiceMimeForFileName(name, isWeb: isWeb, isWindows: isWindows);
          final platform = isWindows ? 'windows' : 'web';
          expect(mime('recording1.m4a'), 'audio/mp4', reason: platform);
          expect(mime('RECORDING1.M4A'), 'audio/mp4', reason: platform);
          expect(mime('recording1.wav'), 'audio/wav', reason: platform);
        }
        // mobile / macOS / Linux: iOS-конвертер ogg→CAF ждёт тип от SDK.
        for (final name in ['recording1.m4a', 'recording1.ogg', 'r.wav']) {
          expect(
            voiceMimeForFileName(name, isWeb: false, isWindows: false),
            isNull,
            reason: name,
          );
        }
      },
    );

    // Первые байты MP4, записанного Chrome 153 (ftyp isom) и Media Foundation
    // на Windows (ftyp mp42 — так пишет MPEG-4 sink по умолчанию).
    final headers = {
      'chrome': Uint8List.fromList([
        0x00, 0x00, 0x00, 0x24, 0x66, 0x74, 0x79, 0x70, //
        0x69, 0x73, 0x6f, 0x6d, 0x00, 0x00, 0x02, 0x00,
        0x69, 0x73, 0x6f, 0x6d, 0x69, 0x73, 0x6f, 0x36,
      ]),
      'windows': Uint8List.fromList([
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
        0x6d, 0x70, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00,
        0x6d, 0x70, 0x34, 0x31, 0x69, 0x73, 0x6f, 0x6d,
      ]),
    };

    test('AC-4, AC-14, AC-16: MP4 из Chrome и Media Foundation уходит '
        'audio/mp4, а не video/mp4', () {
      // AC:RL-web-voice-record/4
      // AC:RL-web-voice-record/14
      // AC:RL-web-voice-record/16
      const name = 'recording1.m4a';
      for (final MapEntry(key: platform, value: header) in headers.entries) {
        final isWindows = platform == 'windows';
        // Red-proof: без явного типа SDK распознаёт видео.
        expect(
          MatrixAudioFile(bytes: header, name: name).mimeType,
          'video/mp4',
          reason: platform,
        );
        // Тот же вызов, что в chat.dart onVoiceMessageSend.
        final file = MatrixAudioFile(
          bytes: header,
          name: name,
          mimeType: voiceMimeForFileName(
            name,
            isWeb: !isWindows,
            isWindows: isWindows,
          ),
        );
        expect(file.mimeType, 'audio/mp4', reason: platform);
        expect(file.info['mimetype'], 'audio/mp4', reason: platform);
      }
    });
  });

  group('RecordingViewModel', () {
    late Room room;

    setUpAll(() async {
      wakelockPlusPlatformInstance = _FakeWakelock();
      PathProviderPlatform.instance = _FakePathProvider();
      room = Room(
        id: '!voice:example.invalid',
        client: await prepareTestClient(loggedIn: true),
      );
    });

    tearDown(() => VoiceRecordingGuard.notifier.value = null);

    Future<RecordingViewModelState> pumpModel(
      WidgetTester tester,
      _FakeRecorder recorder, {
      bool? isWindows,
    }) async {
      late RecordingViewModelState state;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('ru'),
          home: Scaffold(
            body: RecordingViewModel(
              createRecorder: () => recorder,
              isWindows: isWindows,
              builder: (context, s) {
                state = s;
                return Text(s.isRecording ? 'recording' : 'idle');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets(
      'AC-5: запись без файла — без исключения, панель и guard сброшены, SnackBar',
      (tester) async {
        // AC:RL-web-voice-record/5
        final recorder = _FakeRecorder(stopPath: null);
        final state = await pumpModel(tester, recorder);

        await tester.runAsync(() => state.startRecording(room));
        await tester.pump();
        expect(find.text('recording'), findsOneWidget);
        expect(VoiceRecordingGuard.notifier.value, isNotNull);

        var sent = false;
        await tester.runAsync(() async {
          state.stopAndSend((_, _, _, _) async => sent = true);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(sent, isFalse);
        expect(find.text('idle'), findsOneWidget);
        expect(VoiceRecordingGuard.notifier.value, isNull);
        expect(
          find.text(
            'Голосовое не записалось. Проверьте доступ к микрофону и '
            'попробуйте ещё раз.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'AC-15: Windows — старт записи упал: подсказка про доступ к микрофону '
      'вместо HRESULT, панель и guard сброшены',
      (tester) async {
        // AC:RL-web-voice-record/15
        final recorder = _FailingStartRecorder();
        final state = await pumpModel(tester, recorder, isWindows: true);

        await tester.runAsync(() => state.startRecording(room));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(recorder.config?.encoder, AudioEncoder.aacLc);
        expect(recorder.config?.sampleRate, windowsAacSampleRate);
        expect(find.text('idle'), findsOneWidget);
        expect(VoiceRecordingGuard.notifier.value, isNull);
        expect(find.textContaining('0x80070005'), findsNothing);
        expect(
          find.text(
            'Не удалось начать запись. Проверьте, что доступ к микрофону '
            'разрешён: Параметры → Конфиденциальность и защита → Микрофон.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('не Windows: текст ошибки старта прежний', (tester) async {
      final state = await pumpModel(
        tester,
        _FailingStartRecorder(),
        isWindows: false,
      );

      await tester.runAsync(() => state.startRecording(room));
      await tester.pumpAndSettle();

      expect(find.textContaining('0x80070005'), findsOneWidget);
    });

    testWidgets(
      'ушли из чата, пока висел системный диалог разрешения — без setState '
      'на размонтированном State',
      (tester) async {
        final recorder = _PendingPermissionRecorder();
        final state = await pumpModel(tester, recorder);

        final started = state.startRecording(room);
        await tester.pumpWidget(const SizedBox());
        recorder.permission.complete(false);
        await tester.runAsync(() => started);
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('AC-7: после отправки рекордер утилизирован (dispose)', (
      tester,
    ) async {
      // AC:RL-web-voice-record/7
      final recorder = _FakeRecorder(stopPath: '/tmp/recording1.ogg');
      final state = await pumpModel(tester, recorder);

      await tester.runAsync(() => state.startRecording(room));
      await tester.pump();

      String? sentPath;
      await tester.runAsync(() async {
        state.stopAndSend((path, _, _, _) async => sentPath = path);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(sentPath, '/tmp/recording1.ogg');
      expect(find.text('idle'), findsOneWidget);
      expect(recorder.disposeCalls, 1);
    });
  });
}
