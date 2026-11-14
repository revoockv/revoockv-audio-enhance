import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import 'butterworth.dart';
import 'sos_filter.dart';

/// The IIR filters of the chain: high-pass, EQ bands, band-pass and K-weighting.
///
/// Peaking and shelf bands follow the RBJ Audio EQ Cookbook; K-weighting uses the
/// sample-rate-independent derivation of libebur128.
final class BiquadFilters {
  /// Highest usable corner as a part of the sample rate (keeps clear of Nyquist).
  static const double maxCorner = 0.45;

  static const int _highPassOrder = 2;
  static const int _bandPassOrder = 2;
  static const double _eqQ = 1.0;
  static final double _shelfQ = 1 / math.sqrt(2);

  // ITU-R BS.1770 K-weighting as derived in libebur128, valid at any sample rate.
  static const double _kShelfHz = 1681.974450955533;
  static const double _kShelfDb = 3.999843853973347;
  static const double _kShelfQ = 0.7071752369554196;
  static const double _kShelfVbExponent = 0.4996667741545416;
  static const double _kHighPassHz = 38.13547087602444;
  static const double _kHighPassQ = 0.5003270373238773;

  /// Creates a new [BiquadFilters].
  const BiquadFilters();

  /// Remove what is below [cornerHz] (12 dB per octave).
  Samples highPass(Samples samples, int sampleRate, {required double cornerHz}) {
    final double corner = math.min(cornerHz, sampleRate * maxCorner);
    final SosFilter filter = Butterworth.highPass(_highPassOrder, corner, sampleRate.toDouble());
    return _each(samples, filter.filter);
  }

  /// Keep [lowHz]-[highHz] without phase shift (filtered forwards and backwards).
  Samples band(Samples samples, int sampleRate, {required double lowHz, required double highHz}) {
    final double high = math.min(highHz, sampleRate * maxCorner);
    if (lowHz >= high) {
      return <Float64List>[for (final Float64List channel in samples) Float64List(channel.length)];
    }
    final SosFilter filter = Butterworth.bandPass(_bandPassOrder, lowHz, high, sampleRate.toDouble());
    return _each(samples, filter.filterZeroPhase);
  }

  /// Apply peaking [bells] `(hz, gainDb)` and an optional [highShelf] `(hz, gainDb)`.
  Samples equalize(
    Samples samples,
    int sampleRate, {
    required List<(double, double)> bells,
    required (double, double)? highShelf,
  }) {
    final List<Biquad> sections = <Biquad>[
      for (final (double hz, double gain) in bells)
        if (gain != 0 && hz > 0) _peaking(hz, gain, sampleRate),
      if (highShelf != null && highShelf.$2 != 0) _highShelf(highShelf.$1, highShelf.$2, sampleRate),
    ];
    if (sections.isEmpty) return samples;
    return _each(samples, SosFilter(sections).filter);
  }

  /// The two K-weighting stages of ITU-R BS.1770 for [sampleRate].
  SosFilter kWeighting(int sampleRate) {
    double k = math.tan(math.pi * _kShelfHz / sampleRate);
    final double vh = math.pow(10, _kShelfDb / 20).toDouble();
    final double vb = math.pow(vh, _kShelfVbExponent).toDouble();
    double q = _kShelfQ;
    double a0 = 1 + k / q + k * k;
    final Biquad shelf = Biquad(
      (vh + vb * k / q + k * k) / a0,
      2 * (k * k - vh) / a0,
      (vh - vb * k / q + k * k) / a0,
      2 * (k * k - 1) / a0,
      (1 - k / q + k * k) / a0,
    );
    k = math.tan(math.pi * _kHighPassHz / sampleRate);
    q = _kHighPassQ;
    a0 = 1 + k / q + k * k;
    final Biquad highPass = Biquad(1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0);
    return SosFilter(<Biquad>[shelf, highPass]);
  }

  Biquad _peaking(double hz, double gainDb, int sampleRate) {
    final double w0 = 2 * math.pi * math.min(hz, sampleRate * maxCorner) / sampleRate;
    final double a = math.pow(10, gainDb / 40).toDouble();
    final double alpha = math.sin(w0) / (2 * _eqQ);
    final double cos = math.cos(w0);
    final double a0 = 1 + alpha / a;
    return Biquad((1 + alpha * a) / a0, -2 * cos / a0, (1 - alpha * a) / a0, -2 * cos / a0, (1 - alpha / a) / a0);
  }

  Biquad _highShelf(double hz, double gainDb, int sampleRate) {
    final double w0 = 2 * math.pi * math.min(hz, sampleRate * maxCorner) / sampleRate;
    final double a = math.pow(10, gainDb / 40).toDouble();
    final double alpha = math.sin(w0) / (2 * _shelfQ);
    final double cos = math.cos(w0);
    final double root = 2 * math.sqrt(a) * alpha;
    final double a0 = (a + 1) - (a - 1) * cos + root;
    return Biquad(
      a * ((a + 1) + (a - 1) * cos + root) / a0,
      -2 * a * ((a - 1) + (a + 1) * cos) / a0,
      a * ((a + 1) + (a - 1) * cos - root) / a0,
      2 * ((a - 1) - (a + 1) * cos) / a0,
      ((a + 1) - (a - 1) * cos - root) / a0,
    );
  }

  static Samples _each(Samples samples, Float64List Function(Float64List) run) => <Float64List>[
    for (final Float64List channel in samples) run(channel),
  ];
}
