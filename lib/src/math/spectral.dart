import 'dart:math' as math;
import 'dart:typed_data';

import '../fft/real_fft.dart';
import '../filters/windows.dart';

/// Spectral estimates, as in `scipy.signal`.
abstract final class Spectral {
  /// `scipy.signal.welch(x, sampleRate, nperseg=segment)`: the power spectral density averaged
  /// over Hann-windowed, half-overlapping segments (each with its mean removed); returns the bin
  /// frequencies and the densities. A signal shorter than [segment] is one segment.
  static (Float64List, Float64List) welch(Float64List x, int sampleRate, {int segment = 256}) {
    final int size = math.min(segment, x.length);
    final int step = size - size ~/ 2;
    final Float64List window = Windows.hannPeriodic(size);
    double windowPower = 0;
    for (final double w in window) {
      windowPower += w * w;
    }
    final RealFft fft = RealFft(size);
    final int bins = fft.bins;
    final Float64List psd = Float64List(bins);
    final Float64List frame = Float64List(size);
    int count = 0;
    for (int start = 0; start + size <= x.length; start += step) {
      double mean = 0;
      for (int i = 0; i < size; i++) {
        mean += x[start + i];
      }
      mean /= size;
      for (int i = 0; i < size; i++) {
        frame[i] = (x[start + i] - mean) * window[i];
      }
      final Float64x2List spectrum = fft.forward(frame);
      for (int k = 0; k < bins; k++) {
        final Float64x2 v = spectrum[k];
        psd[k] += v.x * v.x + v.y * v.y;
      }
      count++;
    }
    final double scale = 1 / (sampleRate * windowPower * math.max(count, 1));
    for (int k = 0; k < bins; k++) {
      final bool edge = k == 0 || (size.isEven && k == bins - 1);
      psd[k] *= edge ? scale : 2 * scale;
    }
    final Float64List freqs = Float64List(bins);
    for (int k = 0; k < bins; k++) {
      freqs[k] = k * sampleRate / size;
    }
    return (freqs, psd);
  }
}
