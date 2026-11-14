import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import '../math/numeric.dart';

/// Window functions and FIR design, as in `scipy.signal`.
abstract final class Windows {
  /// `scipy.signal.get_window('hann', size)`: the periodic Hann window (for spectral analysis).
  static Float64List hannPeriodic(int size) =>
      SampleOps.generate(size, (int n) => 0.5 - 0.5 * math.cos(2 * math.pi * n / size));

  /// `scipy.signal.windows.kaiser(size, beta)`: the symmetric Kaiser window.
  static Float64List kaiser(int size, double beta) {
    final Float64List out = Float64List(size);
    if (size == 1) return out..[0] = 1;
    final double alpha = (size - 1) / 2;
    final double norm = Numeric.besselI0(beta);
    for (int n = 0; n < size; n++) {
      final double ratio = (n - alpha) / alpha;
      out[n] = Numeric.besselI0(beta * math.sqrt(math.max(0, 1 - ratio * ratio))) / norm;
    }
    return out;
  }

  /// `scipy.signal.firwin(taps, cutoff, window=('kaiser', beta))`: a linear-phase low-pass with
  /// [cutoff] as a part of the Nyquist frequency, scaled to unity gain at DC.
  static Float64List firLowPassKaiser(int taps, double cutoff, double beta) {
    final Float64List window = kaiser(taps, beta);
    final double alpha = 0.5 * (taps - 1);
    final Float64List h = Float64List(taps);
    double sum = 0;
    for (int n = 0; n < taps; n++) {
      h[n] = cutoff * Numeric.sinc(cutoff * (n - alpha)) * window[n];
      sum += h[n];
    }
    for (int n = 0; n < taps; n++) {
      h[n] /= sum;
    }
    return h;
  }
}
