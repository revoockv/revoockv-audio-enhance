import 'dart:math' as math;
import 'dart:typed_data';

/// One second-order section (biquad) `[b0, b1, b2, 1, a1, a2]` with `a0` normalised to 1.
final class Biquad {
  /// Feed-forward coefficients.
  final double b0, b1, b2;

  /// Feedback coefficients (`a0` is 1).
  final double a1, a2;

  /// Creates a new [Biquad].
  const Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  /// The row in SciPy's `sos` layout.
  List<double> get row => <double>[b0, b1, b2, 1, a1, a2];

  @override
  String toString() => 'Biquad$row';
}

/// Cascades of biquads, run like `scipy.signal.sosfilt` and `scipy.signal.sosfiltfilt`.
final class SosFilter {
  /// The sections, applied in order.
  final List<Biquad> sections;

  /// Creates a new [SosFilter].
  const SosFilter(this.sections);

  /// `scipy.signal.sosfilt`: filter [input] forwards (direct form II transposed).
  ///
  /// [state] holds two values per section and is updated in place; zeros when omitted.
  Float64List filter(Float64List input, {Float64List? state}) {
    final Float64List z = state ?? Float64List(2 * sections.length);
    // Section by section over the whole signal: the same arithmetic as sample by sample, with
    // the coefficients and the state in registers.
    Float64List current = input;
    for (int s = 0; s < sections.length; s++) {
      final Biquad q = sections[s];
      final double b0 = q.b0, b1 = q.b1, b2 = q.b2, a1 = q.a1, a2 = q.a2;
      double z0 = z[2 * s], z1 = z[2 * s + 1];
      final Float64List out = Float64List(current.length);
      for (int i = 0; i < current.length; i++) {
        final double x = current[i];
        final double y = b0 * x + z0;
        z0 = b1 * x - a1 * y + z1;
        z1 = b2 * x - a2 * y;
        out[i] = y;
      }
      z[2 * s] = z0;
      z[2 * s + 1] = z1;
      current = out;
    }
    return sections.isEmpty ? Float64List.fromList(input) : current;
  }

  /// `scipy.signal.sosfilt_zi`: the state of a step response's steady state, per unit input.
  Float64List steadyState() {
    final Float64List zi = Float64List(2 * sections.length);
    double scale = 1;
    for (int s = 0; s < sections.length; s++) {
      final Biquad q = sections[s];
      // lfilter_zi: solve (I - companion(a).T) zi = b[1:] - a[1:] * b[0].
      final double rhs0 = q.b1 - q.a1 * q.b0;
      final double rhs1 = q.b2 - q.a2 * q.b0;
      final double zi0 = (rhs0 + rhs1) / (1 + q.a1 + q.a2);
      final double zi1 = rhs1 - q.a2 * zi0;
      zi[2 * s] = scale * zi0;
      zi[2 * s + 1] = scale * zi1;
      scale *= (q.b0 + q.b1 + q.b2) / (1 + q.a1 + q.a2);
    }
    return zi;
  }

  /// `scipy.signal.sosfiltfilt` with its default odd padding: zero-phase filtering.
  ///
  /// SciPy refuses inputs no longer than the padding; here the padding shrinks to fit instead.
  Float64List filterZeroPhase(Float64List input) {
    final int n = input.length;
    if (n == 0) return Float64List(0);
    int zeroB2 = 0;
    int zeroA2 = 0;
    for (final Biquad q in sections) {
      if (q.b2 == 0) zeroB2++;
      if (q.a2 == 0) zeroA2++;
    }
    final int taps = 2 * sections.length + 1 - math.min(zeroB2, zeroA2);
    final int padding = math.min(3 * taps, n - 1);
    final Float64List extended = Float64List(n + 2 * padding);
    final double first = input[0];
    final double last = input[n - 1];
    for (int i = 0; i < padding; i++) {
      extended[i] = 2 * first - input[padding - i];
      extended[padding + n + i] = 2 * last - input[n - 2 - i];
    }
    extended.setRange(padding, padding + n, input);
    final Float64List zi = steadyState();
    final Float64List forwardState = Float64List(zi.length);
    for (int i = 0; i < zi.length; i++) {
      forwardState[i] = zi[i] * extended[0];
    }
    final Float64List forward = filter(extended, state: forwardState);
    final Float64List reversed = Float64List(forward.length);
    for (int i = 0; i < forward.length; i++) {
      reversed[i] = forward[forward.length - 1 - i];
    }
    final Float64List backwardState = Float64List(zi.length);
    for (int i = 0; i < zi.length; i++) {
      backwardState[i] = zi[i] * reversed[0];
    }
    final Float64List backward = filter(reversed, state: backwardState);
    final Float64List out = Float64List(n);
    for (int i = 0; i < n; i++) {
      out[i] = backward[backward.length - 1 - padding - i];
    }
    return out;
  }
}
