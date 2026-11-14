import 'dart:math' as math;
import 'dart:typed_data';

import 'package:revoockv_audio_enhance/revoockv_audio_enhance.dart';
import 'package:test/test.dart';

void main() {
  const int rate = 48000;
  final math.Random random = math.Random(7);
  final Float64List voice = SampleOps.generate(
    rate * 3,
    (int i) =>
        0.3 * math.sin(2 * math.pi * 220 * i / rate) +
        0.1 * math.sin(2 * math.pi * 1760 * i / rate) +
        0.01 * (random.nextDouble() - 0.5),
  );
  const MonoWidener widener = MonoWidener();

  double rms(Float64List x) => math.sqrt(x.fold<double>(0, (double s, double v) => s + v * v) / x.length);

  test('a mono take becomes two channels whose sum is the take itself', () {
    final Samples wide = widener.widen(<Float64List>[voice], rate, widthDb: -12);
    expect(wide, hasLength(2));
    for (int i = 0; i < voice.length; i++) {
      expect((wide[0][i] + wide[1][i]) / 2, closeTo(voice[i], 1e-12));
    }
  });

  test('the sides are the given level under the voice and the channels differ', () {
    final Samples wide = widener.widen(<Float64List>[voice], rate, widthDb: -12);
    final Float64List sides = SampleOps.generate(voice.length, (int i) => (wide[0][i] - wide[1][i]) / 2);
    expect(20 * math.log(rms(sides) / rms(voice)) / math.ln10, closeTo(-12, 1e-9));
    double dot = 0;
    for (int i = 0; i < voice.length; i++) {
      dot += wide[0][i] * wide[1][i];
    }
    final double correlation = dot / (rms(wide[0]) * rms(wide[1]) * voice.length);
    expect(correlation, lessThan(0.99));
    expect(correlation, greaterThan(0.8));
  });

  test('stereo and silence stay as they are', () {
    final Samples stereo = <Float64List>[voice, voice];
    expect(identical(widener.widen(stereo, rate, widthDb: -12), stereo), isTrue);
    final Samples silent = widener.widen(<Float64List>[Float64List(1000)], rate, widthDb: -12);
    expect(silent, hasLength(2));
    expect(silent[0].every((double v) => v == 0) && silent[1].every((double v) => v == 0), isTrue);
  });

  test('the natural preset widens a mono take, loudnessOnly and classic do not', () {
    final PcmAudio mono = PcmAudio(samples: <Float64List>[voice], sampleRate: rate);
    expect(VocalEnhancer().enhance(mono).audio.channels, 2);
    expect(VocalEnhancer().enhance(mono, settings: EnhancePreset.loudnessOnly.settings).audio.channels, 1);
    expect(VocalEnhancer().enhance(mono, settings: EnhancePreset.classic.settings).audio.channels, 1);
  });
}
