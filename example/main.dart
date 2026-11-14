// Enhances a WAV file: dart run example/main.dart input.wav output.wav [natural|studio|loudnessOnly]
import 'package:revoockv_audio_enhance/io.dart';
import 'package:revoockv_audio_enhance/revoockv_audio_enhance.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run example/main.dart input.wav output.wav [preset]');
    return;
  }
  final EnhancePreset preset = EnhancePreset.values.byName(args.length > 2 ? args[2] : 'natural');
  final PcmAudio take = await WavFile.read(args[0]);
  print('before: ${VocalEnhancer().analyze(take)}');
  final EnhanceResult result = VocalEnhancer().enhance(
    take,
    settings: preset.settings,
    onProgress: (EnhanceProgress p) => print('${(p.fraction * 100).round().toString().padLeft(3)} % ${p.label}'),
  );
  await WavFile.write(args[1], result.audio);
  print('after:  ${result.after}');
}
