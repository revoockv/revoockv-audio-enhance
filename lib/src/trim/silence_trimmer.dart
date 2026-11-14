import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import '../loudness/loudness_meter.dart';
import '../math/numeric.dart';

/// Finds where the singing starts and ends, to cut the silence around it.
///
/// Keeps the part between the first and the last loud block, plus a little padding. A 50 ms
/// block is loud when it is 10 dB above the noise floor (10th percentile of the blocks) and no
/// more than 45 dB below the loudest blocks (95th percentile); the second rule keeps breaths and
/// reverb tails of a clean take that has almost no noise.
final class SilenceTrimmer {
  static const double _blockSeconds = 0.05;
  static const double _fadeSeconds = 0.02;
  static const int _minBlocks = 3;
  static const double _noisePercentile = 10;
  static const double _loudPercentile = 95;
  static const double _aboveNoiseDb = 10.0;
  static const double _belowLoudDb = 45.0;

  /// Creates a new [SilenceTrimmer].
  const SilenceTrimmer();

  /// `(start, end)` sample indexes of the part to keep (the whole take if unsure).
  (int, int) keptRange(Samples samples, int sampleRate, {required double paddingSeconds}) {
    final int frames = SampleOps.frames(samples);
    final int block = math.max(1, Numeric.roundHalfEven(_blockSeconds * sampleRate));
    final int blocks = frames ~/ block;
    if (blocks < _minBlocks) return (0, frames);
    final Float64List levels = LoudnessMeter.blockLevelsDb(samples, block, blocks);
    final Float64List sorted = Numeric.sorted(levels);
    final double threshold = math.max(
      Numeric.percentileOfSorted(sorted, _noisePercentile) + _aboveNoiseDb,
      Numeric.percentileOfSorted(sorted, _loudPercentile) - _belowLoudDb,
    );
    int first = -1;
    int last = -1;
    for (int b = 0; b < blocks; b++) {
      if (levels[b] > threshold) {
        if (first < 0) first = b;
        last = b;
      }
    }
    if (first < 0) return (0, frames);
    final int padding = Numeric.roundHalfEven(paddingSeconds * sampleRate);
    return (math.max(0, first * block - padding), math.min(frames, (last + 1) * block + padding));
  }

  /// `samples[start:end]` with short fades where it was cut.
  Samples cut(Samples samples, int sampleRate, {required int start, required int end}) {
    final int frames = SampleOps.frames(samples);
    final int kept = end - start;
    final int fade = math.min(Numeric.roundHalfEven(_fadeSeconds * sampleRate), kept ~/ 2);
    final Float64List ramp = Numeric.linspace(0, 1, math.max(fade, 0));
    return <Float64List>[
      for (final Float64List channel in samples)
        () {
          final Float64List out = Float64List.fromList(channel.sublist(start, end));
          if (fade > 0) {
            if (start > 0) {
              for (int i = 0; i < fade; i++) {
                out[i] *= ramp[i];
              }
            }
            if (end < frames) {
              for (int i = 0; i < fade; i++) {
                out[kept - fade + i] *= ramp[fade - 1 - i];
              }
            }
          }
          return out;
        }(),
    ];
  }
}
