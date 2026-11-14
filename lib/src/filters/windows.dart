import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import '../fft/real_fft.dart';
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

  /// `scipy.signal.get_window('hamming', size, fftbins=False)`: the symmetric Hamming window.
  static Float64List hamming(int size) => size == 1
      ? Float64List.fromList(<double>[1])
      : SampleOps.generate(size, (int n) => 0.54 - 0.46 * math.cos(2 * math.pi * n / (size - 1)));

  /// `scipy.signal.firwin2(taps, freqs, gains, fs=sampleRate)`: a linear-phase FIR (odd [taps])
  /// whose amplitude response passes through [gains] (linear) at [freqs] (Hz, from 0 to the
  /// Nyquist frequency, ascending), designed by frequency sampling with a Hamming window.
  static Float64List firwin2(int taps, List<double> freqs, List<double> gains, double sampleRate) {
    final double nyquist = sampleRate / 2;
    if (freqs.first != 0 || freqs.last != nyquist) {
      throw ArgumentError('freqs must start at 0 and end at the Nyquist frequency');
    }
    final int points = 1 + (1 << (math.log(taps) / math.ln2).ceil());
    final int size = 2 * (points - 1);
    final Float64x2List spectrum = Float64x2List(points);
    final Float64List grid = Numeric.linspace(0, nyquist, points);
    for (int k = 0; k < points; k++) {
      final double gain = Numeric.interp(grid[k], freqs, gains);
      // Delay by (taps - 1) / 2 samples, so the first taps of the inverse FFT are the filter.
      final double phase = -(taps - 1) / 2 * math.pi * grid[k] / nyquist;
      spectrum[k] = Float64x2(gain * math.cos(phase), gain * math.sin(phase));
    }
    final Float64List full = RealFft(size).inverse(spectrum);
    final Float64List window = hamming(taps);
    return SampleOps.generate(taps, (int n) => full[n] * window[n]);
  }
}
