import 'package:record/record.dart';

/// Кодек и частота записи голосового.
typedef VoiceCodec = ({AudioEncoder encoder, int? sampleRate});

/// WAV-фолбэк на Web пишется несжатым PCM: 16 кГц моно = 32 КБ/с, т.е. 300 с
/// ≈ 9,6 МБ — в лимит сервиса расшифровки (20 МБ). На 44,1 кГц вышло бы ≈ 26 МБ.
const int webWavSampleRate = 16000;

/// AAC-энкодер Media Foundation принимает только 44,1/48 кГц — частоту на
/// Windows не берём из настроек, а фиксируем.
const int windowsAacSampleRate = 44100;

/// Выбор кодека записи. На Web — AAC (`audio/mp4`): WebM/Opus, который браузер
/// пишет по умолчанию, не играют iOS/macOS-получатели (CAF-конвертер умеет
/// только ogg). Firefox MP4 не пишет → WAV, он играет везде.
/// Windows: `record_windows` отвечает «opus поддержан», если в системе есть
/// Opus-MFT, но профиля opus у плагина нет — `start` падает `E_NOTIMPL`.
/// Поэтому там только AAC или WAV, как на Web.
/// [sampleRate] = null — частота из настроек записи.
Future<VoiceCodec> resolveVoiceCodec({
  required bool isWeb,
  required bool isIOS,
  required bool isWindows,
  required Future<bool> Function(AudioEncoder) supports,
}) async {
  if (isWeb) {
    if (await supports(AudioEncoder.aacLc)) {
      return (encoder: AudioEncoder.aacLc, sampleRate: null);
    }
    return (encoder: AudioEncoder.wav, sampleRate: webWavSampleRate);
  }
  if (isWindows) {
    if (await supports(AudioEncoder.aacLc)) {
      return (encoder: AudioEncoder.aacLc, sampleRate: windowsAacSampleRate);
    }
    return (encoder: AudioEncoder.wav, sampleRate: webWavSampleRate);
  }
  if (isIOS) return (encoder: AudioEncoder.aacLc, sampleRate: null);
  if (await supports(AudioEncoder.opus)) {
    return (encoder: AudioEncoder.opus, sampleRate: null);
  }
  return (encoder: AudioEncoder.aacLc, sampleRate: null);
}

/// Явный mimetype голосового с Web и Windows. SDK определяет его по байтам, и
/// MP4 из Chrome (`ftypisom`) и из Media Foundation (`ftypmp42`) получает
/// `video/mp4` — такое голосовое не узнают ни плеер, ни бот Лиза (фильтр
/// `audio/*`). На остальном нативе — null: там SDK уже даёт верный тип, а iOS
/// конвертирует Android-ogg в CAF только при точном `audio/ogg`.
String? voiceMimeForFileName(
  String fileName, {
  required bool isWeb,
  required bool isWindows,
}) {
  if (!isWeb && !isWindows) return null;
  final name = fileName.toLowerCase();
  if (name.endsWith('.m4a')) return 'audio/mp4';
  if (name.endsWith('.wav')) return 'audio/wav';
  return null;
}

/// Где композер показывает микрофон. Web — с заявки №44, Windows — с
/// 2026-09-29; Linux нет (`record_linux` зовёт внешние бинари, мы их не везём).
bool canRecordVoice({
  required bool isWeb,
  required bool isMobile,
  required bool isMacOS,
  required bool isWindows,
}) => isMobile || isMacOS || isWeb || isWindows;
