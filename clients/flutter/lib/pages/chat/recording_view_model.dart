import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/object_url.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/voice_recording_codec.dart';
import 'package:liza/utils/voice_recording_guard.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'events/audio_player.dart';

class RecordingViewModel extends StatefulWidget {
  final Widget Function(BuildContext, RecordingViewModelState) builder;

  /// Подмена рекордера в тестах.
  final AudioRecorder Function()? createRecorder;

  /// Подмена платформы в тестах (на VM `Platform.isWindows` не подделать).
  final bool? isWindows;

  const RecordingViewModel({
    required this.builder,
    this.createRecorder,
    this.isWindows,
    super.key,
  });

  @override
  RecordingViewModelState createState() => RecordingViewModelState();
}

class RecordingViewModelState extends State<RecordingViewModel> {
  // Синхронизировано с backend max_audio_duration_seconds
  // (servers/transcribe/app/config.py) — дольше сервис всё равно откажется
  // транскрибировать файл, поэтому запись авто-завершается на том же пороге,
  // как это делает Liza: сообщение отправляется, а не обрывается молча.
  static const Duration maxRecordingDuration = Duration(seconds: 300);

  Timer? _recorderSubscription;
  Duration duration = Duration.zero;

  bool isSending = false;

  bool get isRecording => _audioRecorder != null;

  AudioRecorder? _audioRecorder;
  final List<double> amplitudeTimeline = [];

  String? fileName;

  bool isPaused = false;

  bool get _isWindows => widget.isWindows ?? PlatformInfos.isWindows;

  // Дескриптор для VoiceRecordingGuard — чтобы точки навигации (PopScope чата,
  // тап по другому чату в списке) могли предупредить об обрыве записи.
  ActiveVoiceRecording? _guard;

  Future<void> Function(String, int, List<int>, String?)? _onAutoStopSend;

  Future<void> startRecording(
    Room room, {
    Future<void> Function(String, int, List<int>, String?)?
    onMaxDurationReached,
  }) async {
    _onAutoStopSend = onMaxDurationReached;
    room.client.getConfig(); // Preload server file configuration.
    if (PlatformInfos.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt < 19) {
        showOkAlertDialog(
          context: context,
          title: L10n.of(context).unsupportedAndroidVersion,
          message: L10n.of(context).unsupportedAndroidVersionLong,
          okLabel: L10n.of(context).close,
        );
        return;
      }
    }

    final audioRecorder = _audioRecorder ??=
        (widget.createRecorder ?? AudioRecorder.new)();

    final hasPermission = await audioRecorder.hasPermission();
    // Системный диалог разрешения может висеть секундами — за это время
    // пользователь успевает уйти из чата, и State уже размонтирован.
    if (!mounted) return;
    if (hasPermission != true) {
      // isRecording = «рекордер есть»: без сброса композер при следующей
      // перерисовке показал бы панель записи, которая ничего не пишет.
      setState(_reset);
      showOkAlertDialog(
        context: context,
        title: L10n.of(context).oopsSomethingWentWrong,
        message: L10n.of(context).noPermission,
      );
      return;
    }

    setState(() {});

    try {
      // Параллельно определяем кодек и путь для записи
      final codecFuture = resolveVoiceCodec(
        isWeb: kIsWeb,
        isIOS: PlatformInfos.isIOS,
        isWindows: _isWindows,
        supports: audioRecorder.isEncoderSupported,
      );
      final pathFuture = kIsWeb
          ? Future.value(null)
          : getTemporaryDirectory().then((dir) => dir.path);

      final results = await Future.wait([codecFuture, pathFuture]);
      final voiceCodec = results[0] as VoiceCodec;
      final codec = voiceCodec.encoder;
      final tempDirPath = results[1] as String?;

      fileName =
          'recording${DateTime.now().microsecondsSinceEpoch}.${codec.fileExtension}';
      final path = tempDirPath != null
          ? path_lib.join(tempDirPath, fileName)
          : '';

      await WakelockPlus.enable();

      HapticFeedback.mediumImpact();

      await audioRecorder.start(
        RecordConfig(
          bitRate: AppSettings.audioRecordingBitRate.value,
          sampleRate:
              voiceCodec.sampleRate ??
              AppSettings.audioRecordingSamplingRate.value,
          numChannels: AppSettings.audioRecordingNumChannels.value,
          autoGain: AppSettings.audioRecordingAutoGain.value,
          echoCancel: AppSettings.audioRecordingEchoCancel.value,
          noiseSuppress: AppSettings.audioRecordingNoiseSuppress.value,
          encoder: codec,
        ),
        path: path,
      );
      setState(() => duration = Duration.zero);
      _subscribe();
      _guard = ActiveVoiceRecording(durationOf: () => duration, cancel: cancel);
      VoiceRecordingGuard.register(_guard!);
    } catch (e, s) {
      Logs().w('Unable to start voice message recording', e, s);
      if (!mounted) return;
      // На Windows `hasPermission` всегда true: микрофон, запрещённый в
      // параметрах конфиденциальности, всплывает только здесь — HRESULT
      // пользователю ничего не скажет.
      showOkAlertDialog(
        context: context,
        title: L10n.of(context).oopsSomethingWentWrong,
        message: _isWindows
            ? L10n.of(context).voiceRecordingFailedWindows
            : e.toString(),
      );
      setState(_reset);
    }
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  void _subscribe() {
    _recorderSubscription?.cancel();
    _recorderSubscription = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) async {
      final amplitude = await _audioRecorder!.getAmplitude();
      var value = 100 + amplitude.current * 2;
      value = value < 1 ? 1 : value;
      amplitudeTimeline.add(value);
      setState(() {
        duration += const Duration(milliseconds: 100);
      });
      if (duration >= maxRecordingDuration && !isSending) {
        timer.cancel();
        final onAutoStopSend = _onAutoStopSend;
        if (onAutoStopSend != null) {
          stopAndSend(onAutoStopSend);
        } else {
          cancel();
        }
      }
    });
  }

  void _reset() {
    _unregisterGuard();
    WakelockPlus.disable();
    _recorderSubscription?.cancel();
    // dispose сам останавливает запись; без него рекордер (на Web — ещё и
    // MediaRecorder/AudioContext вкладки) жил до конца процесса. На Web
    // сначала cancel: он освобождает blob URL прерванной записи.
    final recorder = _audioRecorder;
    _audioRecorder = null;
    if (recorder != null) {
      (kIsWeb ? recorder.cancel() : Future<void>.value()).whenComplete(
        recorder.dispose,
      );
    }
    isSending = false;
    fileName = null;
    duration = Duration.zero;
    amplitudeTimeline.clear();
    isPaused = false;
    _onAutoStopSend = null;
  }

  void _unregisterGuard() {
    final guard = _guard;
    if (guard != null) {
      VoiceRecordingGuard.unregister(guard);
      _guard = null;
    }
  }

  void cancel() {
    setState(() {
      _reset();
    });
  }

  void pause() {
    _audioRecorder?.pause();
    _recorderSubscription?.cancel();
    setState(() {
      isPaused = true;
    });
  }

  void resume() {
    _audioRecorder?.resume();
    _subscribe();
    setState(() {
      isPaused = false;
    });
  }

  void stopAndSend(
    Future<void> Function(
      String path,
      int duration,
      List<int> waveform,
      String? fileName,
    )
    onSend,
  ) async {
    _recorderSubscription?.cancel();
    final path = await _audioRecorder?.stop();
    if (!mounted) return;

    if (path == null) {
      // На Web MediaRecorder глотает ошибку старта (record_web), и провал
      // всплывает только здесь. Раньше тут был throw — панель записи зависала.
      Logs().w('Voice message recording produced no file');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).voiceRecordingFailed)),
      );
      cancel();
      return;
    }
    const waveCount = AudioPlayerWidget.wavesCount;
    final step = amplitudeTimeline.length < waveCount
        ? 1
        : (amplitudeTimeline.length / waveCount).round();
    final waveform = <int>[];
    for (var i = 0; i < amplitudeTimeline.length; i += step) {
      waveform.add((amplitudeTimeline[i] / 100 * 1024).round());
    }

    // Отправка началась — отменять уже нечего, снимаем guard, чтобы навигация
    // во время досыла не показывала диалог «сбросить запись?».
    _unregisterGuard();
    setState(() {
      isSending = true;
    });
    try {
      await onSend(path, duration.inMilliseconds, waveform, fileName);
    } catch (e, s) {
      Logs().e('Unable to send voice message', e, s);
      if (!mounted) return;
      setState(() {
        isSending = false;
      });
      return;
    } finally {
      if (kIsWeb) revokeObjectUrl(path);
    }
    if (!mounted) return;

    cancel();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, this);
}

extension on AudioEncoder {
  String get fileExtension {
    switch (this) {
      case AudioEncoder.aacLc:
      case AudioEncoder.aacEld:
      case AudioEncoder.aacHe:
        return 'm4a';
      case AudioEncoder.opus:
        return 'ogg';
      case AudioEncoder.wav:
        return 'wav';
      case AudioEncoder.amrNb:
      case AudioEncoder.amrWb:
      case AudioEncoder.flac:
      case AudioEncoder.pcm16bits:
        throw UnsupportedError('Not yet used');
    }
  }
}
