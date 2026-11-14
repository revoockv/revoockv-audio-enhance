import 'dart:math' as math;

import '../audio/pcm_audio.dart';
import '../dynamics/dynamics_processor.dart';
import '../filters/biquad_filters.dart';
import '../loudness/loudness_meter.dart';
import '../loudness/recording_analysis.dart';
import '../math/numeric.dart';
import '../noise/noise_reducer.dart';
import '../trim/silence_trimmer.dart';
import 'enhance_settings.dart';

/// The step of the chain that has just started.
final class EnhanceProgress {
  /// 1-based number of the step.
  final int step;

  /// Number of steps.
  final int steps;

  /// What the step does, in English ("Reducing noise").
  final String label;

  /// Creates a new [EnhanceProgress].
  const EnhanceProgress({required this.step, required this.steps, required this.label});

  /// Part of the work done before this step, 0.0-1.0.
  double get fraction => (step - 1) / steps;
}

/// The enhanced audio and what was measured before and after.
final class EnhanceResult {
  /// The processed audio.
  final PcmAudio audio;

  /// The settings used.
  final EnhanceSettings settings;

  /// Levels of the input.
  final RecordingAnalysis before;

  /// Levels of the result.
  final RecordingAnalysis after;

  /// Where the result starts in the input, in samples (silence trimmed before it).
  final int keptFrom;

  /// Where the result ends in the input, in samples (exclusive).
  final int keptTo;

  /// Creates a new [EnhanceResult].
  const EnhanceResult({
    required this.audio,
    required this.settings,
    required this.before,
    required this.after,
    required this.keptFrom,
    required this.keptTo,
  });
}

/// Runs the whole vocal chain: high-pass → noise reduction → EQ → de-esser → compressor →
/// loudness → limiter → silence trim.
///
/// Everything is synchronous and CPU-bound; in an app, run it off the UI thread
/// (for example with `Isolate.run`).
final class VocalEnhancer {
  static const double _maxGainDb = 30.0;
  static const int _loudnessPasses = 4;
  static const double _loudnessToleranceLu = 0.2;
  static const double _maxExtraDb = 6.0;

  final BiquadFilters _filters;
  final LoudnessMeter _loudness;
  final DynamicsProcessor _dynamics;
  final NoiseReducer _noise;
  final SilenceTrimmer _trimmer;

  /// Creates a new [VocalEnhancer].
  factory VocalEnhancer() {
    const BiquadFilters filters = BiquadFilters();
    final LoudnessMeter loudness = LoudnessMeter(filters);
    return VocalEnhancer._(
      filters,
      loudness,
      DynamicsProcessor(filters: filters, loudness: loudness),
      const NoiseReducer(),
      const SilenceTrimmer(),
    );
  }

  VocalEnhancer._(this._filters, this._loudness, this._dynamics, this._noise, this._trimmer);

  /// Measures [audio].
  RecordingAnalysis analyze(PcmAudio audio) => _loudness.measure(audio);

  /// Processes [audio] with [settings]; [onProgress] is called when every step starts.
  EnhanceResult enhance(
    PcmAudio audio, {
    EnhanceSettings settings = const EnhanceSettings(),
    void Function(EnhanceProgress progress)? onProgress,
  }) {
    final int rate = audio.sampleRate;
    final List<(String, Samples Function(Samples))> chain = <(String, Samples Function(Samples))>[
      ('Removing rumble', (Samples s) => _highPass(s, rate, settings)),
      ('Reducing noise', (Samples s) => _reduceNoise(s, rate, settings)),
      ('Shaping the tone', (Samples s) => _equalize(s, rate, settings)),
      ('Taming sibilance', (Samples s) => _dynamics.deEss(s, rate, maxReductionDb: settings.deEssDb)),
      ('Evening out the dynamics', (Samples s) => _compress(s, rate, settings)),
      ('Setting the loudness', (Samples s) => _normalize(s, rate, settings)),
      ('Limiting the peaks', (Samples s) => _limit(s, rate, settings)),
    ];
    final int steps = chain.length + 2;
    void report(int step, String label) => onProgress?.call(EnhanceProgress(step: step, steps: steps, label: label));

    report(1, 'Measuring the recording');
    final RecordingAnalysis before = _loudness.measure(audio);
    Samples samples = audio.samples;
    for (int i = 0; i < chain.length; i++) {
      report(i + 2, chain[i].$1);
      samples = chain[i].$2(samples);
    }
    report(steps, 'Trimming the silence');
    int start = 0;
    int end = SampleOps.frames(samples);
    if (settings.trimSilence) {
      (start, end) = _trimmer.keptRange(samples, rate, paddingSeconds: settings.trimPaddingSeconds);
      samples = _trimmer.cut(samples, rate, start: start, end: end);
    }
    final PcmAudio result = PcmAudio(samples: samples, sampleRate: rate);
    return EnhanceResult(
      audio: result,
      settings: settings,
      before: before,
      after: _loudness.measure(result),
      keptFrom: start,
      keptTo: end,
    );
  }

  Samples _highPass(Samples samples, int rate, EnhanceSettings settings) {
    if (settings.highPassHz <= 0) return samples;
    return _filters.highPass(samples, rate, cornerHz: settings.highPassHz);
  }

  Samples _reduceNoise(Samples samples, int rate, EnhanceSettings settings) => _noise.reduce(
    samples,
    rate,
    reductionDb: settings.noiseReductionDb,
    sensitivity: settings.noiseSensitivity,
    profileSeconds: settings.noiseProfileSeconds,
  );

  Samples _equalize(Samples samples, int rate, EnhanceSettings settings) => _filters.equalize(
    samples,
    rate,
    bells: <(double, double)>[(settings.mudHz, settings.mudCutDb), (settings.presenceHz, settings.presenceDb)],
    highShelf: (settings.airHz, settings.airDb),
  );

  Samples _compress(Samples samples, int rate, EnhanceSettings settings) => _dynamics.compress(
    samples,
    rate,
    ratio: settings.compressionRatio,
    thresholdDb: settings.compressionThresholdDb,
    attackSeconds: settings.compressionAttackSeconds,
    releaseSeconds: settings.compressionReleaseSeconds,
  );

  Samples _normalize(Samples samples, int rate, EnhanceSettings settings) {
    final double loudness = _loudness.integratedLufs(samples, rate);
    if (loudness == double.negativeInfinity) return samples;
    final double gainDb = math.min(settings.targetLufs - loudness, _maxGainDb);
    return SampleOps.scaled(samples, Numeric.dbToAmplitude(gainDb));
  }

  /// Limit, then make up the loudness the limiter took away (a few passes).
  Samples _limit(Samples samples, int rate, EnhanceSettings settings) {
    double extraDb = 0.0;
    Samples limited = samples;
    for (int pass = 0; pass < _loudnessPasses; pass++) {
      limited = _dynamics.limit(
        SampleOps.scaled(samples, Numeric.dbToAmplitude(extraDb)),
        rate,
        ceilingDb: settings.truePeakDb,
        releaseSeconds: settings.limiterReleaseSeconds,
      );
      final double shortfall = settings.targetLufs - _loudness.integratedLufs(limited, rate);
      if (!(shortfall > _loudnessToleranceLu) || extraDb >= _maxExtraDb) break;
      extraDb = math.min(extraDb + shortfall, _maxExtraDb);
    }
    return limited;
  }
}
