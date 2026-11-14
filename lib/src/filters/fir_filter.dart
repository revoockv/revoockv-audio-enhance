import 'dart:math' as math;
import 'dart:typed_data';

import '../fft/real_fft.dart';

/// A finite impulse response filter, applied by FFT overlap-add.
final class FirFilter {
  /// The impulse response.
  final Float64List taps;

  /// Creates a new [FirFilter].
  FirFilter(this.taps) {
    if (taps.isEmpty) throw ArgumentError.value(taps, 'taps', 'no taps');
  }

  /// `scipy.signal.fftconvolve(input, taps, mode='same')`: the convolution, as long as [input]
  /// and centred on it, so a linear-phase filter adds no delay.
  Float64List filterSame(Float64List input) {
    final int n = input.length;
    final int m = taps.length;
    if (n == 0) return Float64List(0);
    int size = 1;
    while (size < 2 * m) {
      size <<= 1;
    }
    size = math.max(size, 1 << 14);
    final int block = size - m + 1;
    final RealFft fft = RealFft(size);
    final Float64x2List kernel = fft.forward(Float64List(size)..setRange(0, m, taps));
    final Float64List full = Float64List(n + m - 1);
    final Float64List frame = Float64List(size);
    for (int start = 0; start < n; start += block) {
      final int count = math.min(block, n - start);
      frame.fillRange(0, size, 0);
      frame.setRange(0, count, input, start);
      final Float64x2List spectrum = fft.forward(frame);
      for (int k = 0; k < spectrum.length; k++) {
        final Float64x2 a = spectrum[k];
        final Float64x2 b = kernel[k];
        spectrum[k] = Float64x2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
      }
      final Float64List product = fft.inverse(spectrum);
      final int end = math.min(full.length, start + count + m - 1);
      for (int i = start; i < end; i++) {
        full[i] += product[i - start];
      }
    }
    final int offset = (m - 1) ~/ 2;
    return Float64List.sublistView(full, offset, offset + n);
  }
}
