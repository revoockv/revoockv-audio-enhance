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
/// reverb tails of a clean take that has almost no noise. Silence is always at least 25 dB under
/// the loudest blocks: a take that is loud all along (music from the speaker under the voice) has
/// nothing to cut, however quiet its quietest part.
final class SilenceTrimmer {
  static const double _blockSeconds = 0.05;

  /// Default fade where the take is cut.
  static const double defaultFadeSeconds = 0.02;
  static const int _minBlocks = 3;
  static const double _noisePercentile = 10;
  static const double _loudPercentile = 95;

  /// Default rise above the noise floor that makes a block loud.
  static const double defaultAboveNoiseDb = 10.0;

  /// Default distance under the loudest blocks within which a block is still loud.
  static const double defaultBelowLoudDb = 45.0;

  /// Default least distance of silence under the loudest blocks.
  static const double defaultSilenceBelowLoudDb = 25.0;

  /// Creates a new [SilenceTrimmer].
  const SilenceTrimmer();

  /// `(start, end)` sample indexes of the part to keep (the whole take if unsure).
  ///
  /// [aboveNoiseDb], [belowLoudDb] and [silenceBelowLoudDb] are the three rules above.
  (int, int) keptRange(
    Samples samples,
    int sampleRate, {
    required double paddingSeconds,
    double aboveNoiseDb = defaultAboveNoiseDb,
    double belowLoudDb = defaultBelowLoudDb,
    double silenceBelowLoudDb = defaultSilenceBelowLoudDb,
  }) {
    final int frames = SampleOps.frames(samples);
    final int block = math.max(1, Numeric.roundHalfEven(_blockSeconds * sampleRate));
    final int blocks = frames ~/ block;
    if (blocks < _minBlocks) return (0, frames);
    final Float64List levels = LoudnessMeter.blockLevelsDb(samples, block, blocks);
    final Float64List sorted = Numeric.sorted(levels);
    final double loudest = Numeric.percentileOfSorted(sorted, _loudPercentile);
    final double threshold = math.min(
      math.max(Numeric.percentileOfSorted(sorted, _noisePercentile) + aboveNoiseDb, loudest - belowLoudDb),
      loudest - silenceBelowLoudDb,
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

  /// `samples[start:end]` with fades of [fadeSeconds] where it was cut.
  Samples cut(
    Samples samples,
    int sampleRate, {
    required int start,
    required int end,
    double fadeSeconds = defaultFadeSeconds,
  }) {
    final int frames = SampleOps.frames(samples);
    final int kept = end - start;
    final int fade = math.min(Numeric.roundHalfEven(fadeSeconds * sampleRate), kept ~/ 2);
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
