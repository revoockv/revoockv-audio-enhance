import 'dart:math' as math;

import '../audio/pcm_audio.dart';
import '../dynamics/dynamics_processor.dart';
import '../filters/biquad_filters.dart';
import '../loudness/loudness_meter.dart';
import '../loudness/recording_analysis.dart';
import '../math/numeric.dart';
import '../noise/noise_reducer.dart';
import '../stereo/mono_widener.dart';
import '../stereo/stereo_aligner.dart';
import '../tone/tone_balancer.dart';
import '../trim/silence_trimmer.dart';
import '../task/audio_progress.dart';
import '../task/audio_task.dart';
import 'enhance_settings.dart';

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

/// Runs the whole vocal chain: stereo alignment → tone balance → high-pass → noise reduction →
/// EQ → de-esser → compressor → expander → mono widening → loudness → limiter → silence trim.
///
/// Three ways to call every operation:
/// - [enhance] / [analyze] run right here, synchronously; pass `onProgress` to follow the steps;
/// - [enhanceAsync] / [analyzeAsync] run in the background and give a [Future];
/// - [enhanceTask] runs in the background and gives an [AudioTask]: a [Stream] of progress, the
///   result and `cancel()`.
final class VocalEnhancer {
  static const int _loudnessPasses = 4;
  static const double _loudnessToleranceLu = 0.2;
  static const double _maxExtraDb = 6.0;

  final BiquadFilters _filters;
  final LoudnessMeter _loudness;
  final DynamicsProcessor _dynamics;
  final NoiseReducer _noise;
  final SilenceTrimmer _trimmer;
  final StereoAligner _aligner;
  final ToneBalancer _tone;
  final MonoWidener _widener;

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
      const StereoAligner(),
      const ToneBalancer(),
      const MonoWidener(),
    );
  }

  VocalEnhancer._(
    this._filters,
    this._loudness,
    this._dynamics,
    this._noise,
    this._trimmer,
    this._aligner,
    this._tone,
    this._widener,
  );

  /// Measures [audio].
  RecordingAnalysis analyze(PcmAudio audio) => _loudness.measure(audio);

  /// Measures [audio] in the background.
  Future<RecordingAnalysis> analyzeAsync(PcmAudio audio) =>
      AudioTask<RecordingAnalysis>.start((AudioProgressListener report) => VocalEnhancer().analyze(audio)).result;

  /// [enhance] in the background, without progress reports.
  Future<EnhanceResult> enhanceAsync(PcmAudio audio, {EnhanceSettings settings = const EnhanceSettings()}) =>
      enhanceTask(audio, settings: settings).result;

  /// [enhance] in the background: listen to [AudioTask.progress] (optional), await
  /// [AudioTask.result], or [AudioTask.cancel] it.
  AudioTask<EnhanceResult> enhanceTask(PcmAudio audio, {EnhanceSettings settings = const EnhanceSettings()}) =>
      AudioTask<EnhanceResult>.start(
        (AudioProgressListener report) => VocalEnhancer().enhance(audio, settings: settings, onProgress: report),
      );

  /// Processes [audio] with [settings]; [onProgress] is called when every step starts, and
  /// during the longer steps too.
  EnhanceResult enhance(
    PcmAudio audio, {
    EnhanceSettings settings = const EnhanceSettings(),
    AudioProgressListener? onProgress,
  }) {
    final int rate = audio.sampleRate;
    final List<(String, Samples Function(Samples, void Function(double)))> chain =
        <(String, Samples Function(Samples, void Function(double)))>[
          ('Aligning the channels', (Samples s, _) => settings.alignStereo ? _aligner.align(s, rate) : s),
          ('Balancing the tone', (Samples s, _) => _balanceTone(s, rate, settings)),
          ('Removing rumble', (Samples s, _) => _highPass(s, rate, settings)),
          ('Reducing noise', (Samples s, void Function(double) part) => _reduceNoise(s, rate, settings, part)),
          ('Shaping the tone', (Samples s, _) => _equalize(s, rate, settings)),
          ('Taming sibilance', (Samples s, _) => _dynamics.deEss(s, rate, maxReductionDb: settings.deEssDb)),
          ('Evening out the dynamics', (Samples s, _) => _compress(s, rate, settings)),
          ('Quieting the pauses', (Samples s, _) => _expand(s, rate, settings)),
          (
            'Widening the stereo',
            (Samples s, _) => settings.widenMono ? _widener.widen(s, rate, widthDb: settings.monoWidthDb) : s,
          ),
          ('Setting the loudness', (Samples s, _) => _normalize(s, rate, settings)),
          ('Limiting the peaks', (Samples s, _) => _limit(s, rate, settings)),
        ];
    final int steps = chain.length + 2;
    void report(int step, String label, [double part = 0]) =>
        onProgress?.call(AudioProgress(step: step, steps: steps, label: label, stepFraction: part));

    report(1, 'Measuring the recording');
    final RecordingAnalysis before = _loudness.measure(audio);
    Samples samples = audio.samples;
    for (int i = 0; i < chain.length; i++) {
      final (String label, Samples Function(Samples, void Function(double)) run) = chain[i];
      report(i + 2, label);
      samples = run(samples, (double part) => report(i + 2, label, part));
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

  Samples _balanceTone(Samples samples, int rate, EnhanceSettings settings) {
    if (!settings.balancesTone) return samples;
    return _tone.balance(
      samples,
      rate,
      curve: settings.toneCurve,
      maxBoostDb: settings.toneMaxBoostDb,
      maxCutDb: settings.toneMaxCutDb,
    );
  }

  Samples _expand(Samples samples, int rate, EnhanceSettings settings) => _dynamics.expand(
    samples,
    rate,
    belowDb: settings.expanderBelowDb,
    ratio: settings.expanderRatio,
    floorDb: settings.expanderFloorDb,
  );

  Samples _highPass(Samples samples, int rate, EnhanceSettings settings) {
    if (settings.highPassHz <= 0) return samples;
    return _filters.highPass(samples, rate, cornerHz: settings.highPassHz);
  }

  Samples _reduceNoise(Samples samples, int rate, EnhanceSettings settings, void Function(double) part) =>
      _noise.reduce(
        samples,
        rate,
        reductionDb: settings.noiseReductionDb,
        sensitivity: settings.noiseSensitivity,
        profileSeconds: settings.noiseProfileSeconds,
        onProgress: part,
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
    final double gainDb = math.min(settings.targetLufs - loudness, settings.maxGainDb);
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
