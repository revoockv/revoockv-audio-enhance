import 'dart:math' as math;

import 'sos_filter.dart';

/// Digital Butterworth filters, designed like `scipy.signal.butter(..., output='sos')`:
/// the analog prototype is pre-warped, transformed and mapped with the bilinear transform.
abstract final class Butterworth {
  /// A high-pass of [order] with its -3 dB corner at [cornerHz].
  static SosFilter highPass(int order, double cornerHz, double sampleRate) {
    final double warped = _warp(cornerHz, sampleRate);
    final List<_Complex> prototype = _prototypePoles(order);
    // lp2hp_zpk: poles wo / p, `order` zeros at the origin, gain 1 / prod(-p).
    final List<_Complex> poles = <_Complex>[for (final _Complex p in prototype) _Complex(warped, 0) / p];
    _Complex gain = const _Complex(1, 0);
    for (final _Complex p in prototype) {
      gain = gain / -p;
    }
    final List<_Complex> zeros = List<_Complex>.filled(order, const _Complex(0, 0));
    return _bilinearToSos(zeros, poles, gain.re);
  }

  /// A band-pass of [order] (twice as many poles) between [lowHz] and [highHz].
  static SosFilter bandPass(int order, double lowHz, double highHz, double sampleRate) {
    final double low = _warp(lowHz, sampleRate);
    final double high = _warp(highHz, sampleRate);
    final double bandwidth = high - low;
    final double centre = math.sqrt(low * high);
    final List<_Complex> prototype = _prototypePoles(order);
    // lp2bp_zpk.
    final List<_Complex> scaled = <_Complex>[for (final _Complex p in prototype) p * (bandwidth / 2)];
    final List<_Complex> poles = <_Complex>[
      for (final _Complex p in scaled) p + (p * p - _Complex(centre * centre, 0)).sqrt(),
      for (final _Complex p in scaled) p - (p * p - _Complex(centre * centre, 0)).sqrt(),
    ];
    final List<_Complex> zeros = List<_Complex>.filled(order, const _Complex(0, 0));
    return _bilinearToSos(zeros, poles, math.pow(bandwidth, order).toDouble());
  }

  /// Pre-warped analog frequency for `fs = 2` after normalising by the Nyquist frequency.
  static double _warp(double hz, double sampleRate) {
    final double normalised = 2 * hz / sampleRate;
    return 2 * 2 * math.tan(math.pi * normalised / 2);
  }

  /// `scipy.signal.buttap`: poles `-exp(j pi m / (2 order))`, `m = -order+1, -order+3, …`.
  static List<_Complex> _prototypePoles(int order) => <_Complex>[
    for (int m = -order + 1; m < order; m += 2)
      -_Complex(math.cos(math.pi * m / (2 * order)), math.sin(math.pi * m / (2 * order))),
  ];

  /// `bilinear_zpk` with `fs = 2`, then `zpk2sos` pairing each conjugate pole pair with the two
  /// real zeros nearest to it; the gain goes into the first section.
  static SosFilter _bilinearToSos(List<_Complex> zeros, List<_Complex> poles, double gain) {
    const _Complex fs2 = _Complex(4, 0);
    final List<_Complex> digitalZeros = <_Complex>[
      for (final _Complex z in zeros) (fs2 + z) / (fs2 - z),
      for (int i = zeros.length; i < poles.length; i++) const _Complex(-1, 0),
    ];
    final List<_Complex> digitalPoles = <_Complex>[for (final _Complex p in poles) (fs2 + p) / (fs2 - p)];
    _Complex numerator = const _Complex(1, 0);
    for (final _Complex z in zeros) {
      numerator = numerator * (fs2 - z);
    }
    _Complex denominator = const _Complex(1, 0);
    for (final _Complex p in poles) {
      denominator = denominator * (fs2 - p);
    }
    final double digitalGain = gain * (numerator / denominator).re;

    // Upper-half-plane poles stand for their conjugate pairs; process the one closest to the
    // unit circle first and put it last, like zpk2sos.
    final List<_Complex> upper = digitalPoles.where((_Complex p) => p.im > 0).toList()
      ..sort((_Complex a, _Complex b) => (1 - a.abs).abs().compareTo((1 - b.abs).abs()));
    final List<double> remaining = <double>[for (final _Complex z in digitalZeros) z.re];
    final List<Biquad> sections = <Biquad>[];
    for (final _Complex p in upper) {
      final double z1 = _takeNearest(remaining, p);
      final double z2 = _takeNearest(remaining, p);
      sections.insert(0, Biquad(1, -(z1 + z2), z1 * z2, -2 * p.re, p.re * p.re + p.im * p.im));
    }
    final Biquad first = sections.first;
    sections[0] = Biquad(first.b0 * digitalGain, first.b1 * digitalGain, first.b2 * digitalGain, first.a1, first.a2);
    return SosFilter(sections);
  }

  static double _takeNearest(List<double> zeros, _Complex pole) {
    int best = 0;
    for (int i = 1; i < zeros.length; i++) {
      if ((_Complex(zeros[i], 0) - pole).abs < (_Complex(zeros[best], 0) - pole).abs) best = i;
    }
    return zeros.removeAt(best);
  }
}

final class _Complex {
  final double re;
  final double im;

  const _Complex(this.re, this.im);

  _Complex operator +(_Complex other) => _Complex(re + other.re, im + other.im);

  _Complex operator -(_Complex other) => _Complex(re - other.re, im - other.im);

  _Complex operator -() => _Complex(-re, -im);

  _Complex operator *(Object other) => switch (other) {
    final _Complex c => _Complex(re * c.re - im * c.im, re * c.im + im * c.re),
    final num n => _Complex(re * n, im * n),
    _ => throw ArgumentError.value(other),
  };

  _Complex operator /(_Complex other) {
    final double d = other.re * other.re + other.im * other.im;
    return _Complex((re * other.re + im * other.im) / d, (im * other.re - re * other.im) / d);
  }

  double get abs => math.sqrt(re * re + im * im);

  /// Principal square root.
  _Complex sqrt() {
    final double r = abs;
    final double real = math.sqrt((r + re) / 2);
    final double imag = math.sqrt((r - re) / 2);
    return _Complex(real, im < 0 ? -imag : imag);
  }
}
