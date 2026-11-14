import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// Real-input FFT of one size, a thin wrapper over [fftea](https://pub.dev/packages/fftea).
///
/// Works like `numpy.fft.rfft` / `numpy.fft.irfft`: [forward] returns the `size ~/ 2 + 1`
/// non-negative frequency bins, [inverse] turns such a half spectrum back into `size` samples.
final class RealFft {
  /// Number of samples per transform.
  final int size;

  final FFT _fft;
  final Float64x2List _work;

  /// Creates a new [RealFft]; any size works, powers of two are fastest.
  RealFft(this.size) : _fft = FFT(size), _work = Float64x2List(size);

  /// Number of bins of a half spectrum.
  int get bins => size ~/ 2 + 1;

  /// The half spectrum of [samples] (`size` values).
  Float64x2List forward(Float64List samples) {
    if (samples.length != size) throw ArgumentError.value(samples.length, 'samples.length');
    return Float64x2List.fromList(_fft.realFft(samples).discardConjugates());
  }

  /// The `size` samples whose half spectrum is [spectrum] (`bins` values, consumed).
  ///
  /// Like `numpy.fft.irfft`, only the real parts of the DC and Nyquist bins matter.
  Float64List inverse(Float64x2List spectrum) {
    if (spectrum.length != bins) throw ArgumentError.value(spectrum.length, 'spectrum.length');
    return _fft.realInverseFft(spectrum.createConjugates(size));
  }

  /// The half spectra of two signals with one complex FFT of `a + i b` (twice as fast as two
  /// calls of [forward]). [b] may be omitted; its spectrum is then all zeros.
  (Float64x2List, Float64x2List) forwardPair(Float64List a, [Float64List? b]) {
    if (a.length != size || (b != null && b.length != size)) throw ArgumentError('both signals need $size samples');
    final Float64x2List z = _work;
    if (b == null) {
      for (int i = 0; i < size; i++) {
        z[i] = Float64x2(a[i], 0);
      }
    } else {
      for (int i = 0; i < size; i++) {
        z[i] = Float64x2(a[i], b[i]);
      }
    }
    _fft.inPlaceFft(z);
    final Float64x2List outA = Float64x2List(bins);
    final Float64x2List outB = Float64x2List(bins);
    for (int k = 0; k < bins; k++) {
      final Float64x2 zk = z[k];
      final Float64x2 zm = z[(size - k) % size];
      // A = (Z[k] + conj Z[N-k]) / 2, B = (Z[k] - conj Z[N-k]) / 2i.
      outA[k] = Float64x2((zk.x + zm.x) * 0.5, (zk.y - zm.y) * 0.5);
      outB[k] = Float64x2((zk.y + zm.y) * 0.5, (zm.x - zk.x) * 0.5);
    }
    return (outA, outB);
  }

  /// The signals of two half spectra with one complex inverse FFT (twice as fast as two calls of
  /// [inverse]). [b] may be omitted; the second result is then all zeros.
  (Float64List, Float64List) inversePair(Float64x2List a, [Float64x2List? b]) {
    if (a.length != bins || (b != null && b.length != bins)) throw ArgumentError('both spectra need $bins bins');
    final Float64x2List z = _work;
    final Float64x2List bb = b ?? Float64x2List(bins);
    // Z = A + i B over the whole circle (A and B Hermitian); its inverse is a + i b. The inverse
    // comes from a forward FFT of conj Z, conjugated and divided by N:
    // conj(A + i B) = (ar - bi) - i (ai + br), and A[N-k] = conj A[k] on the upper half.
    for (int k = 0; k < bins; k++) {
      final Float64x2 ak = a[k];
      final Float64x2 bk = bb[k];
      z[k] = Float64x2(ak.x - bk.y, -(ak.y + bk.x));
    }
    for (int k = bins; k < size; k++) {
      final Float64x2 ak = a[size - k];
      final Float64x2 bk = bb[size - k];
      z[k] = Float64x2(ak.x + bk.y, ak.y - bk.x);
    }
    // Like numpy.fft.irfft, only the real parts of the DC and Nyquist bins count.
    z[0] = Float64x2(a[0].x, -bb[0].x);
    if (size.isEven) z[size ~/ 2] = Float64x2(a[size ~/ 2].x, -bb[size ~/ 2].x);
    _fft.inPlaceFft(z);
    final Float64List outA = Float64List(size);
    final Float64List outB = Float64List(size);
    final double scale = 1 / size;
    for (int n = 0; n < size; n++) {
      outA[n] = z[n].x * scale;
      outB[n] = -z[n].y * scale;
    }
    return (outA, outB);
  }

  /// [forwardPair] of two windowed frames of [source], starting at [startA] and [startB]
  /// ([startB] < 0: none), written into [outA] / [outB] (`bins` values each).
  void forwardWindowedPair(
    Float64List source,
    Float64List window,
    int startA,
    int startB,
    Float64x2List outA,
    Float64x2List outB,
  ) {
    final Float64x2List z = _work;
    if (startB < 0) {
      for (int i = 0; i < size; i++) {
        z[i] = Float64x2(source[startA + i] * window[i], 0);
      }
    } else {
      for (int i = 0; i < size; i++) {
        final double w = window[i];
        z[i] = Float64x2(source[startA + i] * w, source[startB + i] * w);
      }
    }
    _fft.inPlaceFft(z);
    for (int k = 0; k < bins; k++) {
      final Float64x2 zk = z[k];
      final Float64x2 zm = z[(size - k) % size];
      outA[k] = Float64x2((zk.x + zm.x) * 0.5, (zk.y - zm.y) * 0.5);
      outB[k] = Float64x2((zk.y + zm.y) * 0.5, (zm.x - zk.x) * 0.5);
    }
  }

  /// [inversePair] of [a] and [b] ([b] null: zeros), each result multiplied by [window] and
  /// added into [target] at [startA] / [startB] (overlap-add).
  void inverseWindowedPairAdd(
    Float64x2List a,
    Float64x2List? b,
    Float64List window,
    Float64List target,
    int startA,
    int startB,
  ) {
    final Float64x2List z = _work;
    if (b == null) {
      for (int k = 0; k < bins; k++) {
        final Float64x2 ak = a[k];
        z[k] = Float64x2(ak.x, -ak.y);
      }
      for (int k = bins; k < size; k++) {
        z[k] = a[size - k];
      }
      z[0] = Float64x2(a[0].x, 0);
      if (size.isEven) z[size ~/ 2] = Float64x2(a[size ~/ 2].x, 0);
    } else {
      for (int k = 0; k < bins; k++) {
        final Float64x2 ak = a[k];
        final Float64x2 bk = b[k];
        z[k] = Float64x2(ak.x - bk.y, -(ak.y + bk.x));
      }
      for (int k = bins; k < size; k++) {
        final Float64x2 ak = a[size - k];
        final Float64x2 bk = b[size - k];
        z[k] = Float64x2(ak.x + bk.y, ak.y - bk.x);
      }
      z[0] = Float64x2(a[0].x, -b[0].x);
      if (size.isEven) z[size ~/ 2] = Float64x2(a[size ~/ 2].x, -b[size ~/ 2].x);
    }
    _fft.inPlaceFft(z);
    final double scale = 1 / size;
    for (int n = 0; n < size; n++) {
      target[startA + n] += z[n].x * scale * window[n];
    }
    if (b != null) {
      for (int n = 0; n < size; n++) {
        target[startB + n] -= z[n].y * scale * window[n];
      }
    }
  }

  /// Magnitudes of the bins of [spectrum].
  static Float64List magnitudes(Float64x2List spectrum) => spectrum.magnitudes();
}
