/// WAV files on disk (needs `dart:io`, so not for the web).
library;

import 'dart:io';

import 'revoockv_audio_enhance.dart';

/// Reads and writes WAV files.
abstract final class WavFile {
  /// Decodes the WAV file at [path].
  static Future<PcmAudio> read(String path) async => WavCodec.decode(await File(path).readAsBytes());

  /// Writes [audio] as 24-bit PCM to [path], through a temporary file renamed at the end.
  static Future<void> write(String path, PcmAudio audio) async {
    final File target = File(path);
    await target.parent.create(recursive: true);
    final File temporary = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await temporary.writeAsBytes(WavCodec.encode24(audio), flush: true);
      await temporary.rename(target.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}
