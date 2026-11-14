import 'dart:math' as math;
import 'dart:typed_data';

/// Numeric helpers that behave exactly like their Python / NumPy counterparts, so the Dart port
/// reproduces the reference engine number for number.
abstract final class Numeric {
  /// Python's `round()`: halves go to the even neighbour (banker's rounding).
  static int roundHalfEven(double value) {
    final double floor = value.floorToDouble();
    final double rest = value - floor;
    if (rest > 0.5) return floor.toInt() + 1;
    if (rest < 0.5) return floor.toInt();
    final int down = floor.toInt();
    return down.isEven ? down : down + 1;
  }

  /// `-(-a // b)`: integer division rounded up, for positive [b].
  static int ceilDiv(int a, int b) => (a + b - 1) ~/ b;

  /// `10 ** (db / 20)`.
  static double dbToAmplitude(double db) => math.pow(10, db / 20).toDouble();

  /// `10 * log10(power)`.
  static double powerToDb(double power) => 10 * math.log(power) / math.ln10;

  /// `20 * log10(amplitude)`.
  static double amplitudeToDb(double amplitude) => 20 * math.log(amplitude) / math.ln10;

  /// `numpy.percentile(values, q)` with the default linear interpolation; [values] is not changed.
  static double percentile(List<double> values, double q) => percentileOfSorted(sorted(values), q);

  /// [percentile] of values that are already sorted ascending.
  static double percentileOfSorted(List<double> sortedValues, double q) {
    final int n = sortedValues.length;
    if (n == 0) throw ArgumentError('percentile of no values');
    final double position = q / 100 * (n - 1);
    final int below = position.floor();
    final int above = math.min(below + 1, n - 1);
    final double fraction = position - below;
    final double low = sortedValues[below];
    final double high = sortedValues[above];
    // NumPy's _lerp: a + (b - a) * t, or b - (b - a) * (1 - t) for t >= 0.5.
    final double diff = high - low;
    return fraction >= 0.5 ? high - diff * (1 - fraction) : low + diff * fraction;
  }

  /// A sorted copy of [values].
  static Float64List sorted(List<double> values) => Float64List.fromList(values)..sort();

  /// The median (50th percentile).
  static double median(List<double> values) => percentile(values, 50);

  /// `numpy.interp(arange(length), xp, fp)` for ascending [xp].
  static Float64List interpAtIndexes(int length, Float64List xp, Float64List fp) {
    final Float64List out = Float64List(length);
    final int last = xp.length - 1;
    int j = 0;
    for (int i = 0; i < length; i++) {
      final double x = i.toDouble();
      if (x <= xp[0]) {
        out[i] = fp[0];
        continue;
      }
      if (x >= xp[last]) {
        out[i] = fp[last];
        continue;
      }
      while (xp[j + 1] <= x) {
        j++;
      }
      final double slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j]);
      out[i] = slope * (x - xp[j]) + fp[j];
    }
    return out;
  }

  /// `numpy.interp(x, xp, fp)` for ascending [xp]: linear, held at the ends.
  static double interp(double x, List<double> xp, List<double> fp) {
    final int last = xp.length - 1;
    if (x <= xp[0]) return fp[0];
    if (x >= xp[last]) return fp[last];
    int j = 0;
    while (xp[j + 1] <= x) {
      j++;
    }
    final double slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j]);
    return slope * (x - xp[j]) + fp[j];
  }

  /// `numpy.linspace(start, stop, count)`.
  static Float64List linspace(double start, double stop, int count) {
    final Float64List out = Float64List(count);
    if (count == 0) return out;
    if (count == 1) {
      out[0] = start;
      return out;
    }
    final double step = (stop - start) / (count - 1);
    for (int i = 0; i < count; i++) {
      out[i] = i * step + start;
    }
    out[count - 1] = stop;
    return out;
  }

  /// The modified Bessel function of the first kind, order 0 (power series).
  static double besselI0(double x) {
    double sum = 1;
    double term = 1;
    final double quarter = x * x / 4;
    for (int k = 1; k < 500; k++) {
      term *= quarter / (k * k);
      sum += term;
      if (term < sum * 1e-17) break;
    }
    return sum;
  }

  /// `numpy.sinc`: `sin(pi x) / (pi x)`, 1 at 0.
  static double sinc(double x) {
    if (x == 0) return 1;
    final double y = math.pi * x;
    return math.sin(y) / y;
  }
}
