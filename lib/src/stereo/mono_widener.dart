import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import '../filters/butterworth.dart';
import '../filters/sos_filter.dart';
import '../math/numeric.dart';

/// Turns a mono take into a mono-compatible stereo one, as if sung in a small, pleasant room.
///
/// The voice stays in the middle (M); the sides (S) are its early reflections: a few short
/// delays (5–35 ms) of the band above 300 Hz and below 7 kHz, with fixed signs. Left is M + S,
/// right is M − S, so summed back to mono (a phone speaker, one Bluetooth box) the sides cancel
/// exactly and the original take comes back, with none of the comb filtering of delay-based
/// pseudo-stereo.
final class MonoWidener {
  /// Delay (ms) and gain of every reflection of the sides.
  static const List<(double, double)> _reflections = <(double, double)>[
    (5.3, 0.62),
    (9.7, -0.55),
    (13.1, 0.47),
    (17.9, -0.41),
    (23.3, 0.33),
    (29.1, -0.27),
    (34.7, 0.21),
  ];

  /// Default bottom of the band of the reflections.
  static const double defaultLowHz = 300;

  /// Default top of the band of the reflections.
  static const double defaultHighHz = 7000;
  static const int _order = 2;

  /// Creates a new [MonoWidener].
  const MonoWidener();

  /// Two channels from the one of [samples], the sides [widthDb] under the voice (for example
  /// −12 dB), the reflections in the [lowHz]–[highHz] band; anything but one channel is returned
  /// as it is.
  Samples widen(
    Samples samples,
    int sampleRate, {
    required double widthDb,
    double lowHz = defaultLowHz,
    double highHz = defaultHighHz,
  }) {
    if (samples.length != 1) return samples;
    final Float64List mid = samples.first;
    final Float64List band = _band(mid, sampleRate, lowHz, highHz);
    final Float64List sides = Float64List(mid.length);
    for (final (double milliseconds, double gain) in _reflections) {
      final int delay = (milliseconds * sampleRate / 1000).round();
      for (int i = delay; i < mid.length; i++) {
        sides[i] += gain * band[i - delay];
      }
    }
    final double midRms = _rms(mid);
    final double sideRms = _rms(sides);
    if (midRms == 0 || sideRms == 0) return <Float64List>[mid, Float64List.fromList(mid)];
    final double scale = Numeric.dbToAmplitude(widthDb) * midRms / sideRms;
    return <Float64List>[
      SampleOps.generate(mid.length, (int i) => mid[i] + scale * sides[i]),
      SampleOps.generate(mid.length, (int i) => mid[i] - scale * sides[i]),
    ];
  }

  static Float64List _band(Float64List input, int sampleRate, double lowHz, double highHz) {
    final double high = math.min(highHz, sampleRate * 0.45);
    if (lowHz >= high) return Float64List(input.length);
    final SosFilter filter = Butterworth.bandPass(_order, lowHz, high, sampleRate.toDouble());
    return filter.filter(input);
  }

  static double _rms(Float64List values) {
    double sum = 0;
    for (final double v in values) {
      sum += v * v;
    }
    return values.isEmpty ? 0 : math.sqrt(sum / values.length);
  }
}
