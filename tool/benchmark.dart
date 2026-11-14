// Times the whole chain: dart run tool/benchmark.dart [seconds] [channels], or [file.wav]
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:revoockv_audio_enhance/io.dart';
import 'package:revoockv_audio_enhance/revoockv_audio_enhance.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args[0].endsWith(".wav")) {
    final PcmAudio audio = await WavFile.read(args[0]);
    for (int run = 0; run < (args.length > 1 ? int.parse(args[1]) : 1); run++) {
      _run(audio);
    }
    return;
  }
  final double seconds = args.isNotEmpty ? double.parse(args[0]) : 180;
  final int channels = args.length > 1 ? int.parse(args[1]) : 2;
  const int rate = 48000;
  final int frames = (seconds * rate).round();
  final math.Random random = math.Random(1);
  final Samples samples = <Float64List>[
    for (int c = 0; c < channels; c++)
      Float64List(frames)..setAll(
        0,
        Iterable<double>.generate(frames, (int i) {
          final double t = i / rate;
          return 0.2 * math.sin(2 * math.pi * 220 * t) * (math.sin(t).abs()) + 0.003 * (random.nextDouble() - 0.5);
        }),
      ),
  ];
  _run(PcmAudio(samples: samples, sampleRate: rate));
}

void _run(PcmAudio audio) {
  print('${audio.durationSeconds.toStringAsFixed(1)} s, ${audio.channels} ch, ${audio.sampleRate} Hz');
  final Stopwatch watch = Stopwatch()..start();
  final EnhanceResult result = VocalEnhancer().enhance(
    audio,
    onProgress: (EnhanceProgress p) => print('${watch.elapsedMilliseconds} ms  ${p.label}'),
  );
  print('${watch.elapsedMilliseconds} ms  done: ${result.after}');
}
