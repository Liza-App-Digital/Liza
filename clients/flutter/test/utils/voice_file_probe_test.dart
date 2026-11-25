// Пустое голосовое (Саша, 24.11): macOS-рекордер записал в m4a сырой PCM
// 0,044 с при таймере 48,9 с, клиент отправил «пшик». Проверяем разбор m4a по
// заголовкам, критерий брака и то, что битый файл не уходит собеседнику.
// MP4 собираются байтами в тесте — пользовательское аудио в репо не кладём.
//
// ledger:RL-voice-empty-recording-guard

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';
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
import 'package:liza/utils/voice_file_probe.dart';
import 'package:liza/utils/voice_recording_guard.dart';
import 'test_client.dart';

Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
Uint8List _u16(int v) => (ByteData(2)..setUint16(0, v)).buffer.asUint8List();

Uint8List _box(String type, List<int> body) =>
    Uint8List.fromList([..._u32(body.length + 8), ...type.codeUnits, ...body]);

Uint8List _mvhd(int timescale, int duration, {int version = 0}) =>
    _box('mvhd', [
      version, 0, 0, 0, //
      if (version == 1) ...[...List.filled(16, 0), ..._u32(timescale)],
      if (version == 1) ...[..._u32(0), ..._u32(duration)],
      if (version == 0) ...[...List.filled(8, 0), ..._u32(timescale)],
      if (version == 0) ..._u32(duration),
      ...List.filled(80, 0),
    ]);

Uint8List _stsd(String codec, {required int sampleRate, required int ch}) {
  final entry = _box(codec, [
    ...List.filled(6, 0), ..._u16(1), // reserved + data_reference_index
    ...List.filled(8, 0), // version, revision, vendor
    ..._u16(ch), ..._u16(16), ..._u16(0), ..._u16(0),
    ..._u32(sampleRate << 16),
  ]);
  return _box('stsd', [0, 0, 0, 0, ..._u32(1), ...entry]);
}

/// m4a: ftyp + moov(mvhd, trak/mdia/minf/stbl/stsd) + mdat; [moovLast] —
/// раскладка Windows MF / iPhone (индекс после данных).
Uint8List _m4a({
  required String codec,
  required int timescale,
  required int duration,
  int sampleRate = 44100,
  int channels = 1,
  int mdatBytes = 1000,
  bool moovLast = false,
  bool fragmented = false,
  int mvhdVersion = 0,
}) {
  final stbl = _box('stbl', _stsd(codec, sampleRate: sampleRate, ch: channels));
  final trak = _box('trak', _box('mdia', _box('minf', stbl)));
  final moov = _box('moov', [
    ..._mvhd(timescale, duration, version: mvhdVersion),
    ...trak,
    if (fragmented) ..._box('mvex', const []),
  ]);
  final ftyp = _box('ftyp', 'M4A \x00\x00\x00\x00M4A mp42isom'.codeUnits);
  final mdat = _box('mdat', List.filled(mdatBytes, 7));
  return Uint8List.fromList([
    ...ftyp,
    if (!moovLast) ...moov,
    ...mdat,
    if (moovLast) ...moov,
  ]);
}

Future<VoiceFileInfo?> _parse(Uint8List bytes) => parseVoiceMp4(
  (offset, length) async => Uint8List.sublistView(
    bytes,
    offset.clamp(0, bytes.length),
    (offset + length).clamp(0, bytes.length),
  ),
  bytes.length,
);

/// Как сломанная запись 24.11: pcm_s24le 48 кГц стерео, 2105 сэмплов.
Uint8List _brokenMac() => _m4a(
  codec: 'lpcm',
  timescale: 48000,
  duration: 2105,
  sampleRate: 48000,
  channels: 2,
  mdatBytes: 12630,
);

class _FakeRecorder implements AudioRecorder {
  _FakeRecorder(this.stopPath);

  final String? stopPath;

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
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

void main() {
  group('parseVoiceMp4', () {
    test('AC-1: сырой PCM 0,044 с (сломанная запись macOS) — брак', () async {
      // AC:RL-voice-empty-recording-guard/1
      final info = (await _parse(_brokenMac()))!;
      expect(info.codec, 'lpcm');
      expect(info.sampleRate, 48000);
      expect(info.channels, 2);
      expect(info.duration.inMilliseconds, 43);
      expect(
        isBrokenVoiceRecording(info, const Duration(milliseconds: 48900)),
        isTrue,
      );
    });

    test(
      'AC-2: нормальный AAC 35,29 с — не брак, длительность из файла',
      () async {
        // AC:RL-voice-empty-recording-guard/2
        final info = (await _parse(
          _m4a(codec: 'mp4a', timescale: 44100, duration: 1556480),
        ))!;
        expect(info.codec, 'mp4a');
        expect(info.sampleRate, 44100);
        expect(info.channels, 1);
        expect(info.duration.inMilliseconds, 35294);
        expect(
          isBrokenVoiceRecording(info, const Duration(milliseconds: 35300)),
          isFalse,
        );
      },
    );

    test('AC-3: нераспознанное — null (отправка как раньше)', () async {
      // AC:RL-voice-empty-recording-guard/3
      final ogg = Uint8List.fromList([
        ...'OggS'.codeUnits,
        ...List.filled(64, 1),
      ]);
      final full = _m4a(codec: 'mp4a', timescale: 44100, duration: 44100);
      final cases = <String, Uint8List>{
        'ogg': ogg,
        'пустой': Uint8List(0),
        'обрезанный moov': Uint8List.sublistView(full, 0, 60),
        'fMP4 (mvex)': _m4a(
          codec: 'mp4a',
          timescale: 44100,
          duration: 0,
          fragmented: true,
        ),
        'fMP4 (moof)': Uint8List.fromList([
          ..._box('ftyp', 'iso5'.codeUnits),
          ..._box('moof', const []),
        ]),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(await _parse(value), isNull, reason: key);
      }
      // Web: path — blob URL, файла нет.
      expect(await probeVoiceFile('blob:https://web.liza.ru/abc'), isNull);
    });

    test(
      'AC-4: AAC < 1 с при таймере ≥ 2 с — брак; запись < 2 с — нет',
      () async {
        // AC:RL-voice-empty-recording-guard/4
        final half = (await _parse(
          _m4a(codec: 'mp4a', timescale: 44100, duration: 22050),
        ))!;
        expect(
          isBrokenVoiceRecording(half, const Duration(seconds: 3)),
          isTrue,
        );
        final short = (await _parse(
          _m4a(codec: 'mp4a', timescale: 44100, duration: 61740),
        ))!;
        expect(
          isBrokenVoiceRecording(short, const Duration(milliseconds: 1900)),
          isFalse,
        );
      },
    );

    test('AC-5: moov после mdat и mvhd v1 разбираются', () async {
      // AC:RL-voice-empty-recording-guard/5
      final tail = (await _parse(
        _m4a(
          codec: 'mp4a',
          timescale: 44100,
          duration: 441000,
          moovLast: true,
          mvhdVersion: 1,
        ),
      ))!;
      expect(tail.duration, const Duration(seconds: 10));
      expect(tail.codec, 'mp4a');
    });

    test('реальный файл с диска читается через probeVoiceFile', () async {
      final dir = await Directory.systemTemp.createTemp('voice_probe');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/rec.m4a')..writeAsBytesSync(_brokenMac());
      final info = await probeVoiceFile(file.path);
      expect(info?.codec, 'lpcm');
      expect(await probeVoiceFile('${dir.path}/missing.m4a'), isNull);
    });
  });

  group('RecordingViewModel.stopAndSend', () {
    late Room room;
    late Directory dir;

    setUpAll(() async {
      wakelockPlusPlatformInstance = _FakeWakelock();
      PathProviderPlatform.instance = _FakePathProvider();
      room = Room(
        id: '!voice:example.invalid',
        client: await prepareTestClient(loggedIn: true),
      );
      dir = await Directory.systemTemp.createTemp('voice_vm');
    });

    tearDownAll(() => dir.delete(recursive: true));
    tearDown(() => VoiceRecordingGuard.notifier.value = null);

    Future<RecordingViewModelState> pumpModel(
      WidgetTester tester,
      String path, {
      VoiceFileProbe? probe,
    }) async {
      late RecordingViewModelState state;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('ru'),
          home: Scaffold(
            body: RecordingViewModel(
              createRecorder: () => _FakeRecorder(path),
              probeFile: probe,
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
      'AC-6: битый файл не отправлен, SnackBar, панель и guard сброшены',
      (tester) async {
        // AC:RL-voice-empty-recording-guard/6
        final path = '${dir.path}/broken.m4a';
        File(path).writeAsBytesSync(_brokenMac());
        final state = await pumpModel(tester, path);
        await tester.runAsync(() => state.startRecording(room));
        state.duration = const Duration(milliseconds: 48900);

        var sent = 0;
        await tester.runAsync(() async {
          state.stopAndSend((_, _, _, _) async => sent++);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(sent, 0);
        expect(find.text('idle'), findsOneWidget);
        expect(VoiceRecordingGuard.notifier.value, isNull);
        expect(
          find.text(
            'Запись не удалась: микрофон не передал звук, голосовое не '
            'отправлено. Проверьте устройство ввода (гарнитуру, внешний '
            'микрофон) и запишите снова.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('нормальный AAC уходит с путём и таймером', (tester) async {
      final path = '${dir.path}/ok.m4a';
      File(path).writeAsBytesSync(
        _m4a(codec: 'mp4a', timescale: 44100, duration: 1556480),
      );
      final state = await pumpModel(tester, path);
      await tester.runAsync(() => state.startRecording(room));
      state.duration = const Duration(milliseconds: 35300);

      String? sentPath;
      int? sentMs;
      await tester.runAsync(() async {
        state.stopAndSend((p, ms, _, _) async {
          sentPath = p;
          sentMs = ms;
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(sentPath, path);
      expect(sentMs, 35300);
    });

    testWidgets('AC-7: двойной тап во время проверки не отправляет дважды', (
      tester,
    ) async {
      // AC:RL-voice-empty-recording-guard/7
      final probing = Completer<VoiceFileInfo?>();
      final state = await pumpModel(
        tester,
        '${dir.path}/any.m4a',
        probe: (_) => probing.future,
      );
      await tester.runAsync(() => state.startRecording(room));

      var sent = 0;
      await tester.runAsync(() async {
        Future<void> send(String _, int _, List<int> _, String? _) async =>
            sent++;
        state.stopAndSend(send);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Кнопка отправки в RecordingInputRow гаснет по isSending.
        expect(state.isSending, isTrue);
        if (!state.isSending) state.stopAndSend(send);
        probing.complete(null);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(sent, 1);
    });
  });
}
