// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:async/async.dart';
import 'package:just_audio/just_audio.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/pages/chat/events/audio_autoplay_service.dart';
import 'package:liza/pages/chat/events/media_caption.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/error_reporter.dart';
import 'package:liza/utils/file_description.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/transcription_service.dart';
import '../../../utils/matrix_sdk_extensions/event_extension.dart';
import '../../../widgets/liza_app.dart';
import '../../../widgets/matrix.dart';

class AudioPlayerWidget extends StatefulWidget {
  final Color color;
  final Color linkColor;
  final double fontSize;
  final Event event;

  /// Время сообщения (Liza-стиль) — в правом НИЖНЕМ углу пузыря, под рядом
  /// контролов. Раньше стояло в конце ряда контролов и отъедало ширину у
  /// осциллограммы/ползунка на узком телефонном пузыре (из-за чего «плашка»
  /// проигрывания уходила от начала дорожки). Вынесено вниз-вправо.
  final Widget? trailing;

  static const int wavesCount = 40;

  const AudioPlayerWidget(
    this.event, {
    required this.color,
    required this.linkColor,
    required this.fontSize,
    this.trailing,
    super.key,
  });

  @override
  AudioPlayerState createState() => AudioPlayerState();
}

enum AudioPlayerStatus { notDownloaded, downloading, downloaded }

class AudioPlayerState extends State<AudioPlayerWidget> {
  static const double buttonSize = 36;

  AudioPlayerStatus status = AudioPlayerStatus.notDownloaded;
  double? _downloadProgress;

  /// Защита от re-entrancy: двойной тап по голосовому, пока идёт
  /// download+setup, иначе создавались ДВА AudioPlayer, первый осиротевал
  /// (утечка нативного плеера + та же гонка per-player канала, что в баге #1).
  bool _setupInProgress = false;

  String? _transcriptionText;
  bool _isTranscribing = false;

  bool get _isVoiceMessage =>
      widget.event.content.containsKey('org.matrix.msc3245.voice');

  late final MatrixState matrix;
  ScaffoldMessengerState? _scaffoldMessenger;
  List<int>? _waveform;
  String? _durationString;
  bool _initialized = false;

  @override
  void dispose() {
    // Своя уборка — строго ДО `super.dispose()` (раньше он стоял первой
    // строкой, и весь хвост метода работал уже на defunct State). Тело вынесено
    // в `_teardown`, потому что в нём есть ранние `return`.
    _teardown();
    super.dispose();
  }

  void _teardown() {
    final audioPlayer = matrix.voiceMessageEventId.value != widget.event.eventId
        ? null
        : matrix.audioPlayer;
    if (audioPlayer != null) {
      if (audioPlayer.playing && !audioPlayer.isAtEndPosition) {
        final scaffoldMessenger = _scaffoldMessenger;
        if (scaffoldMessenger == null) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          scaffoldMessenger.showMaterialBanner(
            MaterialBanner(
              padding: EdgeInsets.zero,
              leading: StreamBuilder(
                stream: audioPlayer.playerStateStream.asBroadcastStream(),
                builder: (context, _) => IconButton(
                  onPressed: () {
                    if (audioPlayer.isAtEndPosition) {
                      audioPlayer.seek(Duration.zero);
                    } else if (audioPlayer.playing) {
                      audioPlayer.pause();
                    } else {
                      audioPlayer.play();
                    }
                  },
                  icon: audioPlayer.playing && !audioPlayer.isAtEndPosition
                      ? const Icon(Icons.pause_outlined)
                      : const Icon(Icons.play_arrow_outlined),
                ),
              ),
              content: StreamBuilder(
                stream: audioPlayer.positionStream.asBroadcastStream(),
                builder: (context, _) => GestureDetector(
                  onTap: () => LizaApp.router.go(
                    '/rooms/${widget.event.room.id}?event=${widget.event.eventId}',
                  ),
                  child: Text(
                    '🎙️ ${audioPlayer.position.minuteSecondString} / ${audioPlayer.duration?.minuteSecondString} - ${widget.event.senderFromMemoryOrFallback.calcDisplayname()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              actions: [
                IconButton(
                  onPressed: () {
                    matrix.audioAutoPlayService.detach();
                    audioPlayer.pause();
                    audioPlayer.dispose();
                    matrix.voiceMessageEventId.value = matrix.audioPlayer =
                        null;

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      scaffoldMessenger.clearMaterialBanners();
                    });
                  },
                  icon: const Icon(Icons.close_outlined),
                ),
              ],
            ),
          );
        });
        return;
      }
      matrix.audioAutoPlayService.detach();
      audioPlayer.pause();
      audioPlayer.dispose();
      matrix.voiceMessageEventId.value = matrix.audioPlayer = null;
    }
  }

  void _onButtonTap() async {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scaffoldMessenger?.clearMaterialBanners();
    });

    // Тап по пузырю, который СЕЙЧАС готовится, = отмена подготовки. Раньше
    // любой тап во время подготовки молча отбрасывался (`isAdvancing`), причём
    // по ЛЮБОМУ аудио в ЛЮБОЙ комнате — флаг один на сервис. Пользователь видел
    // мёртвые кнопки без спиннера и без реакции (жалоба 2026-09-09).
    final preparing = matrix.preparingAudio.value;
    if (preparing?.eventId == widget.event.eventId) {
      await matrix.audioAutoPlayService.cancelAdvance();
      return;
    }

    final currentPlayer =
        matrix.voiceMessageEventId.value != widget.event.eventId
        ? null
        : matrix.audioPlayer;
    if (currentPlayer != null) {
      if (currentPlayer.isAtEndPosition) {
        currentPlayer.seek(Duration.zero);
      } else if (currentPlayer.playing) {
        currentPlayer.pause();
      } else {
        currentPlayer.play();
      }
      return;
    }

    // Re-entrancy guard пузыря: пока ЭТОТ пузырь качает, повторный тап
    // игнорируем — иначе создавались два плеера и первый осиротевал.
    if (_setupInProgress) return;
    // Идёт чужая авто-подготовка → отменяем её и ЖДЁМ, пока `_playEvent`
    // размотается и освободит нативный плеер. Без ожидания dispose старого
    // per-player MethodChannel наложился бы на init нашего — darwin
    // `MissingPluginException` (баг #1). Приоритет — у ПОСЛЕДНЕГО явного
    // действия пользователя (симметрия к identity-guard в `_onCompleted`).
    if (matrix.audioAutoPlayService.isAdvancing) {
      await matrix.audioAutoPlayService.cancelAdvance();
    }
    _setupInProgress = true;
    try {
      await _downloadAndPlay();
    } finally {
      _setupInProgress = false;
    }
  }

  Future<void> _downloadAndPlay() async {
    matrix.voiceMessageEventId.value = widget.event.eventId;
    // Дожидаемся остановки/диспоза предыдущего плеера: нативный darwin-плагин
    // just_audio держит per-player MethodChannel `...methods.<id>`, и наложение
    // dispose старого id на init нового роняло play c MissingPluginException
    // (баг #1, macOS/iOS).
    final previousPlayer = matrix.audioPlayer;
    matrix.audioPlayer = null;
    if (previousPlayer != null) {
      await previousPlayer.stop();
      await previousPlayer.dispose();
    }
    // Прошлая цепочка автозапуска (если была) висела на прежнем плеере —
    // снимаем подписку до подготовки нового, чтобы не сработала на осиротевшем.
    matrix.audioAutoPlayService.detach();
    File? file;
    MatrixFile? matrixFile;

    setState(() => status = AudioPlayerStatus.downloading);
    try {
      // Скачивание+декрипт+CAF — общий с автозапуском путь
      // (`prepareAudioPlaybackFile`), чтобы ручной тап и авто-переход готовили
      // файл одинаково. Прогресс качания рисуем только здесь (виджет смонтирован).
      final prepared = await prepareAudioPlaybackFile(
        widget.event,
        onProgress: (progressPercentage) {
          // mounted-гард ОБЯЗАТЕЛЕН: колбэк исполняется внутри `await for` по
          // телу ответа, и `setState` на размонтированном State бросил бы прямо
          // в цикл чтения — загрузка оборвалась бы, а байты пропали.
          if (!mounted) return;
          setState(() {
            _downloadProgress = progressPercentage < 1
                ? progressPercentage
                : null;
          });
        },
      );
      file = prepared.file;
      matrixFile = prepared.matrixFile;

      if (!mounted) return;
      setState(() {
        status = AudioPlayerStatus.downloaded;
      });
    } catch (e, s) {
      Logs().v('Could not download audio file', e, s);
      // Сбой из-за сна процесса — не авария: без алёрта и без SnackBar
      // (всплыл бы при возврате), но пузырь в тапабельное состояние вернуть надо.
      final suspended = e is AudioPrepareSuspendedException;
      // Копия ещё не залита и байтов нет — это не сбой сети/плеера (#2080/#237).
      if (!suspended && !widget.event.isPendingMediaWithoutBytes) {
        Monitoring.reportAudioIssue(
          prefix: Monitoring.audioFailurePrefix,
          reason: e is TimeoutException ? 'prepare-timeout' : 'download-fail',
          host: widget.event.room.client.homeserver?.host,
          context: audioIssueContext(widget.event, error: e),
        );
      }
      // Сброс состояния ОБЯЗАТЕЛЕН (и никакого `rethrow`). Раньше `status`
      // оставался `downloading` → `build` рисовал спиннер ВМЕСТО `InkWell`, и
      // пузырь становился физически ненажимаемым навсегда; а `rethrow` из
      // `void async _onButtonTap` улетал в root zone (ZONE_ERROR в логе
      // пользователя). Ровно как в соседнем catch на `setSource` ниже.
      if (mounted) {
        setState(() {
          status = AudioPlayerStatus.notDownloaded;
          _downloadProgress = null;
        });
        if (!suspended) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
        }
      }
      if (matrix.voiceMessageEventId.value == widget.event.eventId) {
        matrix.voiceMessageEventId.value = null;
      }
      return;
    }
    if (!context.mounted) return;
    if (matrix.voiceMessageEventId.value != widget.event.eventId) return;

    final audioPlayer = matrix.audioPlayer = AudioPlayer();

    // Источник ОБЯЗАТЕЛЬНО ставим до play и с await: setFilePath/setAudioSource
    // поднимает нативную платформу и регистрирует per-player канал. Без await
    // play уходил на ещё не созданный канал → MissingPluginException (баг #1).
    //
    // try/catch ОБЯЗАТЕЛЕН (LABA-2361): если файл неиграбелен (напр. в старой
    // сборке сервер отдал 404-тело, записанное как «аудио»), ExoPlayer/just_audio
    // бросает «(0) Source error». Раньше эти строки были ВНЕ catch скачивания →
    // ошибка улетала в root zone НЕМО: кнопка молча откатывалась, пользователь
    // не видел ничего. Теперь — понятная ошибка + сброс в исходное состояние.
    try {
      if (file != null) {
        await audioPlayer.setFilePath(file.path);
      } else {
        await audioPlayer.setAudioSource(MatrixFileAudioSource(matrixFile));
      }
    } catch (e, s) {
      Logs().w('[MediaDiag] audio setSource failed', e, s);
      matrix.audioPlayer = null;
      await audioPlayer.dispose();
      Monitoring.reportAudioIssue(
        prefix: Monitoring.audioFailurePrefix,
        reason: 'source-error',
        host: widget.event.room.client.homeserver?.host,
        context: audioIssueContext(
          widget.event,
          playerError: e is PlayerException ? e.message : null,
        ),
      );
      if (mounted) {
        setState(() {
          status = AudioPlayerStatus.notDownloaded;
          _downloadProgress = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
      return;
    }

    // setSpeed — ПОСЛЕ установки источника: до неё он провоцировал лишний
    // цикл ре-активации платформы (смена внутреннего id плеера) до load.
    final savedSpeed = AppSettings.audioPlaybackSpeed.value;
    if (savedSpeed != 1.0) {
      await audioPlayer.setSpeed(savedSpeed);
    }

    // Запускаем цепочку автозапуска: по завершению этого трека сервис сам
    // найдёт и заиграет следующее подряд идущее аудио.
    matrix.audioAutoPlayService.onPlaybackStarted(audioPlayer, widget.event);

    // play() НЕ ждём. Во-первых, just_audio резолвит его лишь В КОНЦЕ трека —
    // под `await` наш `_setupInProgress` держался бы всю длину воспроизведения.
    // Во-вторых, при отказе активации аудиосессии (например, старт из фона)
    // just_audio уходит в ветку, где `playCompleter` не завершается ВООБЩЕ, и
    // возвращённый Future висит вечно — тогда `finally` в `_onButtonTap` не
    // исполнялся бы и кнопка пузыря залипала бы навсегда.
    unawaited(
      audioPlayer.play().onError(
        ErrorReporter(context, 'Unable to play audio message').onErrorCallback,
      ),
    );
  }

  void _toggleSpeed() async {
    final audioPlayer = matrix.audioPlayer;
    if (audioPlayer == null) return;
    double newSpeed;
    switch (audioPlayer.speed) {
      case 1.0:
        newSpeed = 1.25;
        break;
      case 1.25:
        newSpeed = 1.5;
        break;
      case 1.5:
        newSpeed = 2.0;
        break;
      case 2.0:
        newSpeed = 0.5;
        break;
      case 0.5:
      default:
        newSpeed = 1.0;
        break;
    }
    await audioPlayer.setSpeed(newSpeed);
    await AppSettings.audioPlaybackSpeed.setItem(newSpeed);
    setState(() {});
  }

  void _onTranscribe() async {
    setState(() => _isTranscribing = true);
    try {
      final text = await Matrix.of(
        context,
      ).transcriptionService.transcribe(widget.event);
      if (mounted) {
        setState(() {
          _transcriptionText = text;
          _isTranscribing = false;
        });
      }
    } catch (e) {
      // reason из ЗАКРЫТОГО перечня kind (не e.toString() — PII/секрет).
      final kind = e is TranscriptionException ? e.kind.name : 'unknown';
      Monitoring.reportAudioIssue(
        prefix: Monitoring.audioTranscriptionFailurePrefix,
        reason: 'transcription-$kind',
        host: widget.event.room.client.homeserver?.host,
        context: audioIssueContext(widget.event),
      );
      if (mounted) {
        setState(() => _isTranscribing = false);
        final l10n = L10n.of(context);
        String message;
        if (e is TranscriptionException) {
          switch (e.kind) {
            case TranscriptionErrorKind.network:
              message = l10n.transcriptionNetworkFailed;
            case TranscriptionErrorKind.timeout:
              message = l10n.transcriptionTimeout;
            case TranscriptionErrorKind.auth:
              message = l10n.transcriptionAuthFailed;
            case TranscriptionErrorKind.serviceBusy:
              message = l10n.transcriptionServiceBusy;
            case TranscriptionErrorKind.decrypt:
              message = l10n.transcriptionDecryptFailed;
            case TranscriptionErrorKind.server:
            case TranscriptionErrorKind.parse:
              message = l10n.transcriptionServerError;
          }
        } else {
          message = l10n.transcriptionFailed;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  List<int>? _getWaveform() {
    final eventWaveForm = widget.event.content
        .tryGetMap<String, dynamic>('org.matrix.msc1767.audio')
        ?.tryGetList<int>('waveform');
    if (eventWaveForm == null || eventWaveForm.isEmpty) {
      return null;
    }
    while (eventWaveForm.length < AudioPlayerWidget.wavesCount) {
      for (var i = 0; i < eventWaveForm.length; i = i + 2) {
        eventWaveForm.insert(i, eventWaveForm[i]);
      }
    }
    var i = 0;
    final step = (eventWaveForm.length / AudioPlayerWidget.wavesCount).round();
    while (eventWaveForm.length > AudioPlayerWidget.wavesCount) {
      eventWaveForm.removeAt(i);
      i = (i + step) % AudioPlayerWidget.wavesCount;
    }
    return eventWaveForm.map((i) => i > 1024 ? 1024 : i).toList();
  }

  @override
  void initState() {
    super.initState();
    _waveform = _getWaveform();

    final durationInt = widget.event.content
        .tryGetMap<String, dynamic>('info')
        ?.tryGet<int>('duration');
    if (durationInt != null) {
      final duration = Duration(milliseconds: durationInt);
      _durationString = duration.minuteSecondString;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      matrix = Matrix.of(context);
    }
    _scaffoldMessenger = ScaffoldMessenger.of(context);

    if (matrix.voiceMessageEventId.value == widget.event.eventId &&
        matrix.audioPlayer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scaffoldMessenger?.clearMaterialBanners();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waveform = _waveform;

    // Слушаем ОБА нотифаера: активный трек и фазу подготовки. Без второго
    // пузырь, который готовит АВТОпереход, не знал бы об этом вовсе (`status` —
    // локальное поле, а сервис его не трогает) и рисовал бы обычную кнопку play
    // всё время подготовки — «анимация загрузки не включалась» из жалобы.
    return ListenableBuilder(
      listenable: Listenable.merge([
        matrix.voiceMessageEventId,
        matrix.preparingAudio,
      ]),
      builder: (context, _) {
        final eventId = matrix.voiceMessageEventId.value;
        final audioPlayer = eventId != widget.event.eventId
            ? null
            : matrix.audioPlayer;

        // Фаза подготовки ЭТОГО пузыря: либо своя (ручной тап, `status`), либо
        // сервисная (авто-переход цепочки).
        final preparing = matrix.preparingAudio.value;
        final servicePreparing = preparing?.eventId == widget.event.eventId;
        final isPreparing =
            status == AudioPlayerStatus.downloading || servicePreparing;
        final preparingProgress = servicePreparing
            ? preparing?.progress
            : _downloadProgress;

        final fileDescription = widget.event.fileDescription;

        return StreamBuilder<Object>(
          stream: audioPlayer == null
              ? null
              : StreamGroup.merge([
                  audioPlayer.positionStream.asBroadcastStream(),
                  audioPlayer.playerStateStream.asBroadcastStream(),
                ]),
          builder: (context, _) {
            final maxPosition =
                audioPlayer?.duration?.inMilliseconds.toDouble() ?? 1.0;
            var currentPosition =
                audioPlayer?.position.inMilliseconds.toDouble() ?? 0.0;
            if (currentPosition > maxPosition) currentPosition = maxPosition;

            final wavePosition =
                (currentPosition / maxPosition) * AudioPlayerWidget.wavesCount;

            final statusText = audioPlayer == null
                ? _durationString ?? '00:00'
                : audioPlayer.position.minuteSecondString;
            return Padding(
              // Нижний отступ меньше — время в нижнем-правом углу прижато к низу
              // пузыря (см. блок trailing ниже).
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: LizaThemes.columnWidth,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SizedBox(
                          width: buttonSize,
                          height: buttonSize,
                          // Индикатор и отмена живут в ЭТОМ же слоте 36×36 —
                          // нового элемента в Row не добавляем: он увеличил бы
                          // несжимаемый минимум ряда и схлопнул осциллограмму на
                          // узком телефонном пузыре ([[RL-audio-waveform-time]]).
                          child: isPreparing
                              ? InkWell(
                                  borderRadius: BorderRadius.circular(64),
                                  // Тап по индикатору = отмена подготовки:
                                  // пользователь обязан иметь возможность
                                  // прервать ожидание, а не смотреть в мёртвую
                                  // кнопку.
                                  onTap: _onButtonTap,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.color,
                                    value: preparingProgress,
                                  ),
                                )
                              : InkWell(
                                  borderRadius: BorderRadius.circular(64),
                                  // long-press сохраняет файл на устройство —
                                  // это вынос контента (в отличие от onTap
                                  // ниже, который только ВОСПРОИЗВОДИТ аудио
                                  // через плеер в приложении); в защищённом
                                  // канале запрещаем именно сохранение.
                                  onLongPress:
                                      widget.event.room.isContentProtected
                                      ? null
                                      : () {
                                          HapticFeedback.heavyImpact();
                                          widget.event.saveFile(context);
                                        },
                                  onTap: _onButtonTap,
                                  child: Material(
                                    color: widget.color.withAlpha(64),
                                    borderRadius: BorderRadius.circular(64),
                                    child: Icon(
                                      audioPlayer?.playing == true &&
                                              audioPlayer?.isAtEndPosition ==
                                                  false
                                          ? Icons.pause_outlined
                                          : Icons.play_arrow_outlined,
                                      color: widget.color,
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: AudioWaveformSlider(
                            waveform: waveform,
                            color: widget.color,
                            thumbColor:
                                widget.event.senderId ==
                                    widget.event.room.client.userID
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.primary,
                            wavePosition: wavePosition,
                            value: currentPosition,
                            max: maxPosition,
                            onChanged: (position) => audioPlayer == null
                                ? _onButtonTap()
                                : audioPlayer.seek(
                                    Duration(milliseconds: position.round()),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          child: Text(
                            statusText,
                            style: TextStyle(color: widget.color, fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedCrossFade(
                          firstChild: Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isVoiceMessage
                                      ? Icons.mic_none_outlined
                                      : Icons.music_note_outlined,
                                  color: widget.color,
                                ),
                                if (_isVoiceMessage &&
                                    _transcriptionText == null)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: _isTranscribing
                                          ? null
                                          : _onTranscribe,
                                      child: _isTranscribing
                                          ? SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.5,
                                                color: widget.color,
                                              ),
                                            )
                                          : Icon(
                                              Icons.text_fields_outlined,
                                              size: 20,
                                              color: widget.color,
                                            ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          secondChild: Material(
                            color: widget.color.withAlpha(64),
                            borderRadius: BorderRadius.circular(
                              AppConfig.borderRadius,
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(
                                AppConfig.borderRadius,
                              ),
                              onTap: _toggleSpeed,
                              child: SizedBox(
                                width: 32,
                                height: 20,
                                child: Center(
                                  child: Text(
                                    '${audioPlayer?.speed.toString()}x',
                                    style: TextStyle(
                                      color: widget.color,
                                      fontSize: 9,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          alignment: Alignment.center,
                          crossFadeState: audioPlayer == null
                              ? CrossFadeState.showFirst
                              : CrossFadeState.showSecond,
                          duration: LizaThemes.animationDuration,
                        ),
                      ],
                    ),
                  ),
                  if (_transcriptionText != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: LizaThemes.columnWidth,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: 16,
                          right: 16,
                          top: 4,
                        ),
                        // Владелец канала запретил вынос контента — расшифровка
                        // голосового тоже контент поста, поэтому невыделяемый
                        // Text вместо SelectableText.
                        child: widget.event.room.isContentProtected
                            ? Text(
                                _transcriptionText!,
                                style: TextStyle(
                                  color: widget.color,
                                  fontSize: widget.fontSize,
                                ),
                              )
                            : SelectableText(
                                _transcriptionText!,
                                style: TextStyle(
                                  color: widget.color,
                                  fontSize: widget.fontSize,
                                ),
                              ),
                      ),
                    ),
                  if (fileDescription != null) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      // Подпись аудио с разметкой (XL formatted_body) → HTML
                      // (LABA-2207).
                      child: MediaCaption(
                        event: widget.event,
                        textColor: widget.color,
                        linkColor: widget.linkColor,
                      ),
                    ),
                  ],
                  // Время (HH:MM + галочки статуса своих) — в правом НИЖНЕМ углу
                  // пузыря, а не в ряду контролов. Так ряд контролов отдаёт всю
                  // ширину осциллограмме и ползунку (см. фикс «плашки» выше);
                  // размещение повторяет Liza (время под голосовым справа).
                  if (widget.trailing != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: LizaThemes.columnWidth,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2, right: 4),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: widget.trailing!,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Полоса-осциллограмма голосового сообщения (40 столбиков, прогресс закрашен
/// [wavePosition]). Вынесена из [AudioPlayerState.build] в отдельный чистый
/// виджет (примитивы вместо Event), чтобы страж `ledger:RL-audio-waveform-time`
/// рендерил РЕАЛЬНУЮ вёрстку без подъёма Matrix Client (тот вешает пул в
/// testWidgets), как у `MessageTime`/`bot_miniapp_buttons`.
///
/// ⚠️ Инвариант вёрстки: несжимаемый минимум ширины (горизонтальный
/// [horizontalPadding] + суммарный margin столбиков) должен оставаться МАЛЫМ. 40
/// столбиков с margin 1px и padding 16px давали ~112px минимума; после добавления
/// inline-времени в ряд контролов (RL-message-time) на узком пузыре телефона (iOS)
/// `Expanded` осциллограммы ужимался ниже этого порога, ряд столбиков переполнялся
/// и схлопывался в 0 (оставалась только точка-ползунок). Уменьшённые
/// [horizontalPadding]=4
/// и margin=0.5 держат минимум ~48px — осциллограмма выживает в узком пузыре
/// рядом со временем; на широком экране (macOS) столбики лишь чуть плотнее.
class AudioWaveform extends StatelessWidget {
  final List<int> waveform;
  final Color color;
  final double wavePosition;

  /// Горизонтальный отступ полосы. Публичный — чтобы ползунок-Slider в
  /// [AudioPlayerState.build] выравнивался ПО ТОЙ ЖЕ рабочей ширине, что и
  /// столбики (иначе «плашка» проигрывания не совпадала с началом дорожки).
  static const double horizontalPadding = 4.0;
  static const double _barMargin = 0.5;

  const AudioWaveform({
    required this.waveform,
    required this.color,
    required this.wavePosition,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Row(
        children: [
          for (var i = 0; i < AudioPlayerWidget.wavesCount; i++)
            Expanded(
              child: Container(
                height: 32,
                alignment: Alignment.center,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: _barMargin),
                  decoration: BoxDecoration(
                    color: i < wavePosition ? color : color.withAlpha(128),
                    borderRadius: BorderRadius.circular(64),
                  ),
                  height: 32 * (waveform[i] / 1024),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Осциллограмма + выровненный ползунок проигрывания голосового. Вынесена из
/// [AudioPlayerState.build] в чистый публичный виджет (примитивы вместо Event/
/// AudioPlayer), чтобы golden-страж `ledger:RL-audio-waveform-time` рендерил
/// РЕАЛЬНУЮ вёрстку без Matrix Client (тот вешает пул в testWidgets) — как
/// [AudioWaveform]/[CornerTimeLayout]. Golden на копию был бы ложно-зелёным
/// (правка `SliderTheme` не роняет эталон-копию, урок receipts-golden).
///
/// ⚠️ Инвариант: при [value]=0 «плашка» (thumb Slider) стоит в НАЧАЛЕ дорожки и
/// совпадает с левым краем осциллограммы; при проигрывании едет по границе
/// закраски. Держится на трёх вещах, любую из которых нельзя убирать: тот же
/// горизонтальный [AudioWaveform.horizontalPadding] вокруг Slider, `padding:
/// EdgeInsets.zero` в `SliderTheme` (Material-инсет overlay ~24px иначе сдвигает
/// thumb от начала — на узком телефонном пузыре до ~20% ширины, из-за чего
/// непрослушанное аудио выглядело частично проигранным), и `noOverlay` +
/// маленький thumb.
class AudioWaveformSlider extends StatelessWidget {
  final List<int>? waveform;
  final Color color;
  final Color thumbColor;
  final double wavePosition;
  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  const AudioWaveformSlider({
    required this.waveform,
    required this.color,
    required this.thumbColor,
    required this.wavePosition,
    required this.value,
    required this.max,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final waveform = this.waveform;
    return Stack(
      alignment: Alignment.center,
      // Ползунок в value=0 центрируется на левом крае — круг наполовину выходит
      // за границу дорожки; не обрезаем его, чтобы «плашка» читалась в начале.
      clipBehavior: Clip.none,
      children: [
        if (waveform != null)
          AudioWaveform(
            waveform: waveform,
            color: color,
            wavePosition: wavePosition,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AudioWaveform.horizontalPadding,
          ),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              padding: EdgeInsets.zero,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: SizedBox(
              height: 32,
              child: Slider(
                thumbColor: thumbColor,
                activeColor: waveform == null ? color : Colors.transparent,
                inactiveColor: waveform == null
                    ? color.withAlpha(128)
                    : Colors.transparent,
                max: max,
                value: value,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

extension on AudioPlayer {
  /// ⚠️ `duration == null` (длительность ещё/уже неизвестна) — это НЕ «трек в
  /// конце». Раньше здесь стоял `return true`, и тап по такому пузырю уходил в
  /// ветку `seek(Duration.zero)` — то есть `play()` не вызывался НИКОГДА, а
  /// пользователь видел кнопку, которая «не нажимается».
  ///
  /// Loop-guard автоперехода (`duration == null` → не продолжать цепочку) живёт
  /// отдельно в `AudioAutoPlayService._onCompleted` и этой правкой не затронут.
  bool get isAtEndPosition {
    final duration = this.duration;
    if (duration == null) return false;
    return position >= duration;
  }
}

extension on Duration {
  String get minuteSecondString =>
      '${inMinutes.toString().padLeft(2, '0')}:${(inSeconds % 60).toString().padLeft(2, '0')}';
}
