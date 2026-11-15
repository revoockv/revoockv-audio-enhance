import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';

/// Lines up the two channels of a stereo take made with two spaced microphones.
///
/// The microphones of a phone are a few centimetres apart, so one channel lags the other by up
/// to a millisecond; played together they cancel at some frequencies and sound hollow. The
/// aligner finds the lag from the first 20 seconds (cross-correlation within ±1 ms), shifts the
/// later channel and gives both channels the same level. The stereo width stays.
final class StereoAligner {
  /// Default largest delay between the channels that is looked for.
  static const double defaultMaxLagSeconds = 0.001;
  static const int _windowSeconds = 20;

  /// Creates a new [StereoAligner].
  const StereoAligner();

  /// [samples] aligned (a delay of up to [maxLagSeconds]); anything but two channels is returned
  /// as it is.
  Samples align(Samples samples, int sampleRate, {double maxLagSeconds = defaultMaxLagSeconds}) {
    if (samples.length != 2) return samples;
    final int lag = lagOf(samples, sampleRate, maxLagSeconds: maxLagSeconds);
    Float64List left = samples[0];
    Float64List right = samples[1];
    if (lag > 0) left = _advance(left, lag);
    if (lag < 0) right = _advance(right, -lag);
    final double leftRms = _rms(left);
    final double rightRms = _rms(right);
    if (leftRms == 0 || rightRms == 0) return <Float64List>[left, right];
    final double common = math.sqrt(leftRms * rightRms);
    return <Float64List>[
      SampleOps.generate(left.length, (int i) => left[i] * (common / leftRms)),
      SampleOps.generate(right.length, (int i) => right[i] * (common / rightRms)),
    ];
  }

  /// Samples by which the left channel lags the right one (negative: the right one lags).
  int lagOf(Samples samples, int sampleRate, {double maxLagSeconds = defaultMaxLagSeconds}) {
    final Float64List left = samples[0];
    final Float64List right = samples[1];
    final int n = math.min(left.length, sampleRate * _windowSeconds);
    final int reach = (maxLagSeconds * sampleRate).toInt();
    double best = double.negativeInfinity;
    int lag = 0;
    for (int k = -reach; k <= reach; k++) {
      double sum = 0;
      if (k >= 0) {
        for (int i = 0; i < n - k; i++) {
          sum += left[i + k] * right[i];
        }
      } else {
        for (int i = 0; i < n + k; i++) {
          sum += left[i] * right[i - k];
        }
      }
      if (sum > best) {
        best = sum;
        lag = k;
      }
    }
    return lag;
  }

  /// [channel] moved [by] samples earlier, padded with silence at the end.
  static Float64List _advance(Float64List channel, int by) =>
      Float64List(channel.length)..setRange(0, channel.length - by, channel, by);

  static double _rms(Float64List channel) {
    double sum = 0;
    for (final double v in channel) {
      sum += v * v;
    }
    return math.sqrt(sum / channel.length);
  }
}
