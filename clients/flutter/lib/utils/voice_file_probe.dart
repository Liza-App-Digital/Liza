import 'dart:async';
import 'dart:typed_data';

import 'voice_file_probe_stub.dart'
    if (dart.library.io) 'voice_file_probe_io.dart'
    as platform;

/// Что удалось узнать о записанном голосовом из заголовков MP4 (m4a).
class VoiceFileInfo {
  final Duration duration;

  /// fourcc первой записи `stsd`: `mp4a` у AAC, `lpcm`/`sowt`/… у сырого PCM.
  final String codec;
  final int? sampleRate;
  final int? channels;
  final int sizeBytes;

  const VoiceFileInfo({
    required this.duration,
    required this.codec,
    required this.sizeBytes,
    this.sampleRate,
    this.channels,
  });

  @override
  String toString() =>
      'codec=$codec sr=$sampleRate ch=$channels '
      'file=${duration.inMilliseconds}ms size=$sizeBytes';
}

typedef VoiceFileProbe = Future<VoiceFileInfo?> Function(String path);

/// Читает [length] байт с [offset]; короче — значит конец файла.
typedef ReadAt = Future<Uint8List> Function(int offset, int length);

/// Заголовки m4a записанного файла или `null`, если файл не MP4, не разобран
/// или это Web (path — blob URL). `null` = «не знаю» → отправка как раньше.
Future<VoiceFileInfo?> probeVoiceFile(String path) async {
  try {
    return await platform
        .probeVoiceFilePath(path)
        .timeout(const Duration(seconds: 2));
  } catch (_) {
    return null;
  }
}

/// Кодеки, которые наш рекордер в m4a не пишет никогда: AAC просили, а пришёл
/// сырой PCM — значит, ОС проигнорировала настройки энкодера (24.11, macOS:
/// `pcm_s24le` 48 кГц стерео, 0,044 с при таймере 48,9 с).
const _rawPcmCodecs = {'lpcm', 'sowt', 'twos', 'in24', 'in32', 'fl32', 'fl64'};

/// Брак записи (RL-voice-empty-recording-guard): сырой PCM вместо AAC, или
/// звука в файле < 1 с при таймере ≥ 2 с. Без доли от таймера: таймер
/// асинхронный и плывёт, а настоящий сбой отличается в сотни раз.
bool isBrokenVoiceRecording(VoiceFileInfo info, Duration timer) {
  if (_rawPcmCodecs.contains(info.codec)) return true;
  return timer >= const Duration(seconds: 2) &&
      info.duration < const Duration(seconds: 1);
}

const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl'};
const _maxMoovBytes = 4 * 1024 * 1024;

/// Разбор MP4 по атомам: верхний уровень — с seek мимо `mdat` (файл до 300 с
/// не читаем целиком), `moov` — целиком. fMP4 (`mvex`/`moof`: длительность в
/// фрагментах, Web MediaRecorder) → `null`.
Future<VoiceFileInfo?> parseVoiceMp4(ReadAt readAt, int sizeBytes) async {
  Uint8List? moov;
  var sawFtyp = false;
  var offset = 0;
  while (offset + 8 <= sizeBytes) {
    final header = await readAt(offset, 16);
    if (header.length < 8) return null;
    final bd = ByteData.sublistView(header);
    var size = bd.getUint32(0);
    final type = String.fromCharCodes(header.sublist(4, 8));
    var headerSize = 8;
    if (size == 1) {
      if (header.length < 16) return null;
      size = bd.getUint64(8);
      headerSize = 16;
    } else if (size == 0) {
      size = sizeBytes - offset;
    }
    if (size < headerSize || offset + size > sizeBytes) return null;
    if (offset == 0) {
      if (type != 'ftyp') return null;
      sawFtyp = true;
    }
    if (type == 'moof') return null;
    if (type == 'moov') {
      if (size > _maxMoovBytes) return null;
      moov = await readAt(offset + headerSize, size - headerSize);
      if (moov.length != size - headerSize) return null;
    }
    offset += size;
  }
  if (!sawFtyp || moov == null) return null;

  int? timescale, duration, sampleRate, channels;
  String? codec;
  var fragmented = false;

  void walk(Uint8List buf, int start, int end) {
    final bd = ByteData.sublistView(buf);
    var pos = start;
    while (pos + 8 <= end) {
      final size = bd.getUint32(pos);
      if (size < 8 || pos + size > end) return;
      final type = String.fromCharCodes(buf.sublist(pos + 4, pos + 8));
      final body = pos + 8;
      if (type == 'mvex') fragmented = true;
      if (type == 'mvhd' && body + 4 <= pos + size) {
        final version = buf[body];
        if (version == 1 && body + 32 <= pos + size) {
          timescale = bd.getUint32(body + 20);
          duration = bd.getUint64(body + 24);
        } else if (version == 0 && body + 20 <= pos + size) {
          timescale = bd.getUint32(body + 12);
          duration = bd.getUint32(body + 16);
        }
      }
      // stsd: version/flags(4) + count(4), затем первая запись:
      // size(4) fourcc(4) reserved(6) dref(2) ver(2) rev(2) vendor(4)
      // channels(2) bits(2) compId(2) packet(2) rate 16.16(4).
      if (type == 'stsd' && codec == null && body + 16 <= pos + size) {
        final entry = body + 8;
        codec = String.fromCharCodes(buf.sublist(entry + 4, entry + 8));
        if (entry + 36 <= pos + size) {
          channels = bd.getUint16(entry + 24);
          sampleRate = bd.getUint32(entry + 32) >> 16;
        }
      }
      if (_containers.contains(type)) walk(buf, body, pos + size);
      pos += size;
    }
  }

  walk(moov, 0, moov.length);
  final ts = timescale, dur = duration, c = codec;
  if (fragmented || ts == null || ts == 0 || dur == null || c == null) {
    return null;
  }
  return VoiceFileInfo(
    duration: Duration(microseconds: dur * 1000000 ~/ ts),
    codec: c,
    sampleRate: sampleRate,
    channels: channels,
    sizeBytes: sizeBytes,
  );
}
