import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import '../filters/biquad_filters.dart';
import '../loudness/loudness_meter.dart';
import '../math/numeric.dart';

/// De-esser, compressor and true-peak limiter.
///
/// Gains are computed on short frames, smoothed and interpolated to every sample.
final class DynamicsProcessor {
  static const double _powerFloor = 1e-20;
  static const double _compressorFrameSeconds = 0.005;
  static const double _kneeDb = 6.0;
  static const double _deEssFrameSeconds = 0.0025;
  static const double _deEssLowHz = 5000.0;
  static const double _deEssHighHz = 9000.0;

  /// The band counts as sibilant when it is within this many dB of the whole signal.
  static const double _deEssAboveVoiceDb = 10.0;
  static const double _deEssGateDb = -60.0;
  static const double _deEssAttackSeconds = 0.001;
  static const double _deEssReleaseSeconds = 0.04;
  static const int _limiterBlock = 64;
  static const double _limiterLookaheadSeconds = 0.005;
  static const double _minTimeSeconds = 1e-6;
  static const double _expanderFrameSeconds = 0.005;
  static const double _expanderOpenSeconds = 0.005;
  static const double _expanderCloseSeconds = 0.15;

  final BiquadFilters _filters;
  final LoudnessMeter _loudness;

  /// Creates a new [DynamicsProcessor].
  const DynamicsProcessor({required BiquadFilters filters, required LoudnessMeter loudness})
    : _filters = filters,
      _loudness = loudness;

  /// Lower the 5-9 kHz band by up to [maxReductionDb] while it dominates the voice.
  Samples deEss(Samples samples, int sampleRate, {required double maxReductionDb}) {
    if (maxReductionDb <= 0) return samples;
    final Samples band = _filters.band(samples, sampleRate, lowHz: _deEssLowHz, highHz: _deEssHighHz);
    final int frame = math.max(1, Numeric.roundHalfEven(_deEssFrameSeconds * sampleRate));
    final Float64List bandDb = _frameLevelsDb(band, frame);
    final Float64List fullDb = _frameLevelsDb(samples, frame);
    final Float64List target = Float64List(bandDb.length);
    for (int i = 0; i < target.length; i++) {
      final double excess = bandDb[i] - (fullDb[i] - _deEssAboveVoiceDb);
      final double reduction = bandDb[i] > _deEssGateDb ? excess.clamp(0, maxReductionDb).toDouble() : 0.0;
      target[i] = -reduction;
    }
    final Float64List smoothed = _smooth(
      target,
      frameSeconds: frame / sampleRate,
      attackSeconds: _deEssAttackSeconds,
      releaseSeconds: _deEssReleaseSeconds,
    );
    final Float64List gain = _perSample(_dbToGain(smoothed), frame, SampleOps.frames(samples));
    return <Float64List>[
      for (int c = 0; c < samples.length; c++)
        SampleOps.generate(gain.length, (int i) => samples[c][i] - band[c][i] * (1 - gain[i])),
    ];
  }

  /// Compress above [thresholdDb] (relative to the loudness of [samples]) with a 6 dB soft knee.
  Samples compress(
    Samples samples,
    int sampleRate, {
    required double ratio,
    required double thresholdDb,
    required double attackSeconds,
    required double releaseSeconds,
  }) {
    if (ratio <= 1) return samples;
    final double loudness = _loudness.integratedLufs(samples, sampleRate);
    if (loudness.isInfinite) return samples;
    final double threshold = loudness + thresholdDb;
    final int frame = math.max(1, Numeric.roundHalfEven(_compressorFrameSeconds * sampleRate));
    final Float64List levels = _frameLevelsDb(samples, frame);
    const double half = _kneeDb / 2;
    final double slope = 1 / ratio - 1;
    final Float64List reduction = Float64List(levels.length);
    for (int i = 0; i < levels.length; i++) {
      final double over = levels[i] - threshold;
      reduction[i] = over <= -half
          ? 0.0
          : over >= half
          ? slope * over
          : slope * (over + half) * (over + half) / (2 * _kneeDb);
    }
    final Float64List smoothed = _smooth(
      reduction,
      frameSeconds: frame / sampleRate,
      attackSeconds: attackSeconds,
      releaseSeconds: releaseSeconds,
    );
    final Float64List gain = _perSample(_dbToGain(smoothed), frame, SampleOps.frames(samples));
    return <Float64List>[
      for (final Float64List channel in samples) SampleOps.generate(gain.length, (int i) => channel[i] * gain[i]),
    ];
  }

  /// Downward expander: lowers what is more than [belowDb] under the loudness of [samples] by
  /// [ratio]:1 (at most [floorDb]), so the room and the noise between phrases stay quiet. It
  /// opens within 5 ms and closes over 150 ms, so note tails fade naturally.
  Samples expand(
    Samples samples,
    int sampleRate, {
    required double belowDb,
    required double ratio,
    required double floorDb,
  }) {
    if (ratio <= 1) return samples;
    final double loudness = _loudness.integratedLufs(samples, sampleRate);
    if (loudness.isInfinite) return samples;
    final double threshold = loudness - belowDb;
    final int frame = math.max(1, Numeric.roundHalfEven(_expanderFrameSeconds * sampleRate));
    final Float64List levels = _frameLevelsDb(samples, frame);
    final Float64List reduction = Float64List(levels.length);
    for (int i = 0; i < levels.length; i++) {
      final double gain = levels[i] < threshold ? math.max((levels[i] - threshold) * (ratio - 1), floorDb) : 0.0;
      reduction[i] = -gain;
    }
    // A growing reduction (closing) is the "release" of the smoother, a shrinking one the "attack".
    final Float64List smoothed = _smooth(
      reduction,
      frameSeconds: frame / sampleRate,
      attackSeconds: _expanderOpenSeconds,
      releaseSeconds: _expanderCloseSeconds,
    );
    final Float64List gain = _perSample(
      SampleOps.generate(smoothed.length, (int i) => Numeric.dbToAmplitude(-smoothed[i])),
      frame,
      SampleOps.frames(samples),
    );
    return <Float64List>[
      for (final Float64List channel in samples) SampleOps.generate(gain.length, (int i) => channel[i] * gain[i]),
    ];
  }

  /// Keep the inter-sample peaks under [ceilingDb] with a 5 ms look-ahead.
  Samples limit(Samples samples, int sampleRate, {required double ceilingDb, required double releaseSeconds}) {
    final double ceiling = Numeric.dbToAmplitude(ceilingDb);
    final Float64List peaks = _loudness.peaksReaching(samples, ceiling);
    const int block = _limiterBlock;
    final int frames = SampleOps.frames(samples);
    final int blocks = Numeric.ceilDiv(peaks.length, block);
    final Float64List needed = Float64List(blocks);
    for (int b = 0; b < blocks; b++) {
      double peak = 0;
      for (int i = b * block; i < math.min(peaks.length, (b + 1) * block); i++) {
        if (peaks[i] > peak) peak = peaks[i];
      }
      needed[b] = math.min(1.0, ceiling / math.max(peak, _powerFloor));
    }
    final int ahead = math.max(1, (_limiterLookaheadSeconds * sampleRate / block).ceil());
    // earliest[i] = min(needed[i … i + ahead]): the gain is down `ahead` blocks before a peak.
    final Float64List earliest = Float64List(blocks);
    for (int b = 0; b < blocks; b++) {
      double low = 1.0;
      for (int j = b; j <= b + ahead; j++) {
        final double value = j < blocks ? needed[j] : 1.0;
        if (value < low) low = value;
      }
      earliest[b] = low;
    }
    final double recovery = 1 - math.exp(-block / (sampleRate * math.max(releaseSeconds, _minTimeSeconds)));
    final Float64List held = Float64List(blocks);
    double current = 1.0;
    for (int b = 0; b < blocks; b++) {
      final double target = earliest[b];
      current = target < current ? target : math.min(target, current + (1 - current) * recovery);
      held[b] = current;
    }
    // ramped[i] = mean(held[i - ahead … i]); every one of those is ≤ needed[i], so the ramp into
    // a peak never lets it through.
    final Float64List ramped = Float64List(blocks);
    for (int b = 0; b < blocks; b++) {
      double sum = 0;
      for (int j = b - ahead; j <= b; j++) {
        sum += held[math.max(0, j)];
      }
      ramped[b] = math.min(sum / (ahead + 1), needed[b]);
    }
    final Float64List centres = Float64List(blocks);
    for (int b = 0; b < blocks; b++) {
      centres[b] = (b + 0.5) * block;
    }
    final Float64List smooth = Numeric.interpAtIndexes(frames, centres, ramped);
    final Float64List gain = Float64List(frames);
    for (int i = 0; i < frames; i++) {
      gain[i] = math.min(ramped[i ~/ block], smooth[i]);
    }
    return <Float64List>[
      for (final Float64List channel in samples)
        SampleOps.generate(frames, (int i) => (channel[i] * gain[i]).clamp(-ceiling, ceiling)),
    ];
  }

  Float64List _frameLevelsDb(Samples samples, int frame) {
    final int length = SampleOps.frames(samples);
    final int frames = Numeric.ceilDiv(length, frame);
    final Float64List power = SampleOps.meanSquare(samples);
    final Float64List levels = Float64List(frames);
    for (int f = 0; f < frames; f++) {
      double sum = 0;
      final int end = math.min(length, (f + 1) * frame);
      for (int i = f * frame; i < end; i++) {
        sum += power[i];
      }
      levels[f] = Numeric.powerToDb(sum / frame + _powerFloor);
    }
    return levels;
  }

  Float64List _smooth(
    Float64List gainDb, {
    required double frameSeconds,
    required double attackSeconds,
    required double releaseSeconds,
  }) {
    final double attack = attackSeconds > 0 ? math.exp(-frameSeconds / attackSeconds) : 0.0;
    final double release = releaseSeconds > 0 ? math.exp(-frameSeconds / releaseSeconds) : 0.0;
    final Float64List smoothed = Float64List(gainDb.length);
    double current = 0.0;
    for (int i = 0; i < gainDb.length; i++) {
      final double target = gainDb[i];
      final double coefficient = target < current ? attack : release;
      current = coefficient * current + (1 - coefficient) * target;
      smoothed[i] = current;
    }
    return smoothed;
  }

  Float64List _dbToGain(Float64List db) => SampleOps.generate(db.length, (int i) => Numeric.dbToAmplitude(db[i]));

  Float64List _perSample(Float64List frameGain, int frame, int length) {
    final Float64List centres = Float64List(frameGain.length);
    for (int i = 0; i < centres.length; i++) {
      centres[i] = (i + 0.5) * frame;
    }
    return Numeric.interpAtIndexes(length, centres, frameGain);
  }
}
