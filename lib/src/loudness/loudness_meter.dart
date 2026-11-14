import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import '../filters/biquad_filters.dart';
import '../filters/sos_filter.dart';
import '../filters/windows.dart';
import '../math/numeric.dart';
import 'recording_analysis.dart';

/// Measures recordings: loudness (ITU-R BS.1770), true peak and noise floor.
/// Every level is in dB relative to full scale.
final class LoudnessMeter {
  static const double _blockSeconds = 0.4;
  static const double _stepSeconds = 0.1;
  static const double _loudnessOffset = -0.691;
  static const double _absoluteGateLufs = -70.0;
  static const double _relativeGateLu = -10.0;
  static const int _oversampling = 4;
  static const int _peakChunk = 1 << 14;
  static const int _peakPadding = 64;
  static const int _interpolatorHalfLength = 10 * 4;
  static const double _interpolatorBeta = 5.0;

  /// Inter-sample peaks of real audio stay well within 6 dB of the sample peaks.
  static const double _maxOvershoot = 2.0;
  static const double _fullScale = 0.999;
  static const double _levelBlockSeconds = 0.05;
  static const double _noisePercentile = 10;
  static const double _signalPercentile = 90;
  static const double _powerFloor = 1e-20;

  final BiquadFilters _filters;
  Float64List? _fir;
  List<Float64List>? _polyphase;
  double? _bound;
  Float64x2List? _pairs;

  /// Creates a new [LoudnessMeter].
  LoudnessMeter(this._filters);

  /// The low-pass FIR of the 4x oversampling (the one `scipy.signal.resample_poly` designs).
  Float64List get _interpolator =>
      _fir ??= Windows.firLowPassKaiser(2 * _interpolatorHalfLength + 1, 1 / _oversampling, _interpolatorBeta);

  /// The interpolator split into its [_oversampling] phases, each scaled by the factor.
  List<Float64List> get _phases => _polyphase ??= <Float64List>[
    for (int phase = 0; phase < _oversampling; phase++)
      Float64List.fromList(<double>[
        for (int m = phase; m < _interpolator.length; m += _oversampling) _interpolator[m] * _oversampling,
      ]),
  ];

  /// The four phases as SIMD pairs: `[p0 | p1]` for every tap, then `[p2 | p3]`; shorter phases
  /// are padded with zero taps, which leaves every sum unchanged.
  Float64x2List get _phasePairs => _pairs ??= () {
    final List<Float64List> phases = _phases;
    assert(phases.length == 4, 'the SIMD kernel handles exactly 4 phases');
    final int taps = phases.map((Float64List p) => p.length).reduce(math.max);
    double tap(int phase, int t) => t < phases[phase].length ? phases[phase][t] : 0.0;
    final Float64x2List pairs = Float64x2List(2 * taps);
    for (int t = 0; t < taps; t++) {
      pairs[t] = Float64x2(tap(0, t), tap(1, t));
      pairs[taps + t] = Float64x2(tap(2, t), tap(3, t));
    }
    return pairs;
  }();

  /// Gated integrated loudness in LUFS; `-infinity` when everything is below the gate.
  double integratedLufs(Samples samples, int sampleRate) {
    final SosFilter weighting = _filters.kWeighting(sampleRate);
    final int frames = SampleOps.frames(samples);
    final int block = math.max(1, Numeric.roundHalfEven(_blockSeconds * sampleRate));
    final int step = math.max(1, Numeric.roundHalfEven(_stepSeconds * sampleRate));
    final List<Float64List> squares = <Float64List>[
      for (final Float64List channel in samples) _squareInPlace(weighting.filter(channel)),
    ];
    final Float64List power;
    if (frames < block) {
      double total = 0;
      for (final Float64List channel in squares) {
        double sum = 0;
        for (final double v in channel) {
          sum += v;
        }
        total += sum / frames;
      }
      power = Float64List.fromList(<double>[total]);
    } else {
      final int count = (frames - block) ~/ step + 1;
      power = Float64List(count);
      for (final Float64List channel in squares) {
        final Float64List sums = Float64List(frames + 1);
        for (int i = 0; i < frames; i++) {
          sums[i + 1] = sums[i] + channel[i];
        }
        for (int b = 0; b < count; b++) {
          final int start = b * step;
          power[b] += (sums[start + block] - sums[start]) / block;
        }
      }
    }
    final double absoluteGate = _powerOf(_absoluteGateLufs);
    double absoluteSum = 0;
    int absoluteCount = 0;
    for (final double p in power) {
      if (p > absoluteGate) {
        absoluteSum += p;
        absoluteCount++;
      }
    }
    if (absoluteCount == 0) return double.negativeInfinity;
    final double relativeGate = _powerOf(_lufsOf(absoluteSum / absoluteCount) + _relativeGateLu);
    double gatedSum = 0;
    int gatedCount = 0;
    for (final double p in power) {
      if (p > absoluteGate && p > relativeGate) {
        gatedSum += p;
        gatedCount++;
      }
    }
    if (gatedCount == 0) return double.negativeInfinity;
    return _lufsOf(gatedSum / gatedCount);
  }

  /// Highest absolute value of every sample over all channels, inter-sample peaks included.
  ///
  /// Chunks whose inter-sample peaks cannot reach [floor] (their sample peak is more than
  /// twice lower) keep their sample peaks and are not oversampled.
  Float64List oversampledPeaks(Samples samples, {double floor = 0}) => _peaks(samples, chunkFloor: floor);

  /// Like [oversampledPeaks], but every sample whose inter-sample peak provably stays below
  /// [floor] keeps its sample peak: exact wherever the result can reach [floor], and much faster.
  ///
  /// A limiter with its ceiling at [floor] behaves the same with either, because it only acts on
  /// peaks at or above the ceiling.
  Float64List peaksReaching(Samples samples, double floor) =>
      _peaks(samples, chunkFloor: floor, skipBelow: () => floor);

  /// Highest inter-sample peak as a linear amplitude.
  double truePeak(Samples samples) {
    if (SampleOps.frames(samples) == 0) return 0;
    double loudest = 0;
    for (final Float64List channel in samples) {
      for (final double v in channel) {
        if (v.abs() > loudest) loudest = v.abs();
      }
    }
    // Only the maximum matters, so a block that cannot beat the best peak so far is skipped.
    double best = loudest;
    _peaks(
      samples,
      chunkFloor: loudest,
      skipBelow: () => best,
      onPeak: (double peak) {
        if (peak > best) best = peak;
      },
    );
    return best;
  }

  /// The sample peaks, oversampled in every chunk that can reach [chunkFloor] (SciPy's rule) and,
  /// when [skipBelow] is given, only in the blocks whose bound reaches its current value.
  Float64List _peaks(
    Samples samples, {
    required double chunkFloor,
    double Function()? skipBelow,
    void Function(double peak)? onPeak,
  }) {
    final int frames = SampleOps.frames(samples);
    final Float64List samplePeaks = Float64List(frames);
    for (final Float64List channel in samples) {
      for (int i = 0; i < frames; i++) {
        final double v = channel[i].abs();
        if (v > samplePeaks[i]) samplePeaks[i] = v;
      }
    }
    final Float64List peaks = Float64List.fromList(samplePeaks);
    final Float64x2List pairs = _phasePairs;
    final int taps = pairs.length ~/ 2;
    final double gainBound = _gainBound;
    const int reach = _interpolatorHalfLength ~/ _oversampling;
    const int block = 64;
    final Float64List segment = Float64List(_peakChunk + 2 * _peakPadding + 2 * reach);
    for (int start = 0; start < frames; start += _peakChunk) {
      final int end = math.min(frames, start + _peakChunk);
      double chunkPeak = 0;
      for (int i = start; i < end; i++) {
        if (samplePeaks[i] > chunkPeak) chunkPeak = samplePeaks[i];
      }
      if (chunkPeak * _maxOvershoot < chunkFloor) continue;
      // resample_poly over left..right with zeros outside: output phase p of sample i is
      // sum_t phases[p][t] * x[i + reach - t].
      final int left = math.max(0, start - _peakPadding);
      final int right = math.min(frames, end + _peakPadding);
      for (final Float64List channel in samples) {
        segment.fillRange(0, segment.length, 0);
        segment.setRange(reach, reach + right - left, channel, left);
        for (int from = start; from < end; from += block) {
          final int to = math.min(end, from + block);
          if (skipBelow != null) {
            double near = 0;
            for (int i = math.max(left, from - reach); i < math.min(right, to + reach); i++) {
              if (samplePeaks[i] > near) near = samplePeaks[i];
            }
            if (near * gainBound < skipBelow()) continue;
          }
          double blockPeak = 0;
          for (int i = from; i < to; i++) {
            final int centre = i - left + 2 * reach;
            // Phases 0 and 1 in one SIMD lane pair, phases 2 and 3 in the other.
            Float64x2 low = Float64x2.zero();
            Float64x2 high = Float64x2.zero();
            for (int t = 0; t < taps; t++) {
              final Float64x2 x = Float64x2.splat(segment[centre - t]);
              low += pairs[t] * x;
              high += pairs[taps + t] * x;
            }
            final Float64x2 largest = low.abs().max(high.abs());
            double best = peaks[i];
            if (largest.x > best) best = largest.x;
            if (largest.y > best) best = largest.y;
            peaks[i] = best;
            if (best > blockPeak) blockPeak = best;
          }
          onPeak?.call(blockPeak);
        }
      }
    }
    return peaks;
  }

  /// Largest sum of absolute taps of a phase, with a margin for rounding: no output sample can
  /// exceed this times the largest input sample in its reach.
  double get _gainBound => _bound ??=
      _phases
          .map((Float64List taps) => taps.fold<double>(0, (double sum, double tap) => sum + tap.abs()))
          .reduce(math.max) *
      (1 + 1e-9);

  /// The loudness, peaks, clipping and noise floor of [audio].
  RecordingAnalysis measure(PcmAudio audio) {
    final Samples samples = audio.samples;
    final double peak = truePeak(samples);
    final Uint8List atFullScale = Uint8List(audio.frames);
    for (final Float64List channel in samples) {
      for (int i = 0; i < channel.length; i++) {
        if (channel[i].abs() >= _fullScale) atFullScale[i] = 1;
      }
    }
    int clipped = 0;
    for (final int flag in atFullScale) {
      clipped += flag;
    }
    final (double noiseFloor, double loud) = _levelPercentiles(samples, audio.sampleRate);
    return RecordingAnalysis(
      durationSeconds: audio.frames / audio.sampleRate,
      sampleRate: audio.sampleRate,
      channels: audio.channels,
      integratedLufs: integratedLufs(samples, audio.sampleRate),
      truePeakDb: toDb(peak),
      clippedPercent: clipped / audio.frames * 100,
      noiseFloorDb: noiseFloor,
      signalToNoiseDb: loud - noiseFloor,
    );
  }

  /// A linear amplitude in dB (`-infinity` for 0).
  static double toDb(double amplitude) => amplitude > 0 ? Numeric.amplitudeToDb(amplitude) : double.negativeInfinity;

  (double, double) _levelPercentiles(Samples samples, int sampleRate) {
    final int frames = SampleOps.frames(samples);
    final int block = math.max(1, Numeric.roundHalfEven(_levelBlockSeconds * sampleRate));
    final int blocks = frames ~/ block;
    if (blocks == 0) {
      double sum = 0;
      for (final Float64List channel in samples) {
        for (final double v in channel) {
          sum += v * v;
        }
      }
      final double level = Numeric.powerToDb(sum / (frames * samples.length) + _powerFloor);
      return (level, level);
    }
    final Float64List levels = blockLevelsDb(samples, block, blocks);
    final Float64List sorted = Numeric.sorted(levels);
    return (
      Numeric.percentileOfSorted(sorted, _noisePercentile),
      Numeric.percentileOfSorted(sorted, _signalPercentile),
    );
  }

  /// Level in dB of each of the first [blocks] blocks of [block] samples (channels averaged).
  static Float64List blockLevelsDb(Samples samples, int block, int blocks) {
    final Float64List power = SampleOps.meanSquare(samples);
    final Float64List levels = Float64List(blocks);
    for (int b = 0; b < blocks; b++) {
      double sum = 0;
      for (int i = b * block; i < (b + 1) * block; i++) {
        sum += power[i];
      }
      levels[b] = Numeric.powerToDb(sum / block + _powerFloor);
    }
    return levels;
  }

  static Float64List _squareInPlace(Float64List values) {
    for (int i = 0; i < values.length; i++) {
      values[i] *= values[i];
    }
    return values;
  }

  double _powerOf(double lufs) => math.pow(10, (lufs - _loudnessOffset) / 10).toDouble();

  double _lufsOf(double power) => _loudnessOffset + Numeric.powerToDb(power);
}
