import 'dart:io';

import 'voice_file_probe.dart';

Future<VoiceFileInfo?> probeVoiceFilePath(String path) async {
  if (!path.toLowerCase().endsWith('.m4a')) return null;
  final file = await File(path).open();
  try {
    final size = await file.length();
    return await parseVoiceMp4((offset, length) async {
      await file.setPosition(offset);
      return file.read(length);
    }, size);
  } finally {
    await file.close();
  }
}
