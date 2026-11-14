// Compares every tool with the outputs of the Python reference engine (see tool/make_fixtures.py).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:revoockv_audio_enhance/revoockv_audio_enhance.dart';
import 'package:test/test.dart';

/// The fixtures are stored as float32, so they carry about 7 significant digits.
const double _tolerance = 2e-6;

void main() {
  final Map<String, dynamic> index =
      jsonDecode(File('test/fixtures/fixtures.json').readAsStringSync()) as Map<String, dynamic>;

  const BiquadFilters filters = BiquadFilters();
  final LoudnessMeter loudness = LoudnessMeter(filters);
  final DynamicsProcessor dynamics = DynamicsProcessor(filters: filters, loudness: loudness);
  const NoiseReducer noise = NoiseReducer();
  const SilenceTrimmer trimmer = SilenceTrimmer();
  final VocalEnhancer enhancer = VocalEnhancer();

  for (final MapEntry<String, dynamic> entry in index.entries) {
    final String name = entry.key;
    final Map<String, dynamic> info = entry.value as Map<String, dynamic>;
    final int rate = info['sample_rate'] as int;
    final int channels = info['channels'] as int;
    Samples load(String file) => _load('test/fixtures/$name/$file.f32', channels);
    final Samples input = load('input');

    group(name, () {
      test('high-pass', () => _expectClose(filters.highPass(input, rate, cornerHz: 80), load('high_pass')));

      test('zero-phase band-pass', () {
        _expectClose(filters.band(input, rate, lowHz: 5000, highHz: 9000), load('band'));
      });

      test('equalizer', () {
        final Samples out = filters.equalize(
          input,
          rate,
          bells: <(double, double)>[(250, -2), (3500, 1.5)],
          highShelf: (10000, 2),
        );
        _expectClose(out, load('equalize'));
      });

      test('K-weighting coefficients', () {
        final List<dynamic> expected = info['k_weighting'] as List<dynamic>;
        final List<Biquad> sections = filters.kWeighting(rate).sections;
        for (int s = 0; s < sections.length; s++) {
          final List<dynamic> row = expected[s] as List<dynamic>;
          for (int i = 0; i < 6; i++) {
            expect(sections[s].row[i], closeTo((row[i] as num).toDouble(), 1e-12));
          }
        }
      });

      test('integrated loudness', () {
        expect(loudness.integratedLufs(input, rate), closeTo(_number(info['integrated_lufs']), 1e-9));
      });

      test('oversampled peaks and true peak', () {
        _expectClose(<Float64List>[
          loudness.oversampledPeaks(input),
        ], _load('test/fixtures/$name/oversampled_peaks.f32', 1));
        expect(loudness.truePeak(input), closeTo(_number(info['true_peak']), 1e-9));
      });

      test('analysis', () {
        final Map<String, dynamic> expected = info['measure'] as Map<String, dynamic>;
        final RecordingAnalysis analysis = loudness.measure(PcmAudio(samples: input, sampleRate: rate));
        expect(analysis.durationSeconds, closeTo(_number(expected['duration_s']), 1e-12));
        expect(analysis.integratedLufs, closeTo(_number(expected['integrated_lufs']), 1e-9));
        expect(analysis.truePeakDb, closeTo(_number(expected['true_peak_db']), 1e-9));
        expect(analysis.clippedPercent, closeTo(_number(expected['clipped_percent']), 1e-12));
        expect(analysis.noiseFloorDb, closeTo(_number(expected['noise_floor_db']), 1e-9));
        expect(analysis.signalToNoiseDb, closeTo(_number(expected['signal_to_noise_db']), 1e-9));
      });

      test('de-esser', () => _expectClose(dynamics.deEss(input, rate, maxReductionDb: 6), load('de_ess')));

      test('compressor', () {
        final Samples out = dynamics.compress(
          input,
          rate,
          ratio: 3,
          thresholdDb: -2,
          attackSeconds: 0.01,
          releaseSeconds: 0.15,
        );
        _expectClose(out, load('compress'));
      });

      test('limiter', () {
        final Samples out = dynamics.limit(SampleOps.scaled(input, 4), rate, ceilingDb: -1, releaseSeconds: 0.08);
        _expectClose(out, load('limit'));
      });

      test('noise reduction, quietest frames as the profile', () {
        final Samples out = noise.reduce(input, rate, reductionDb: 16, sensitivity: 1.5, profileSeconds: 0);
        _expectClose(out, load('noise_auto'));
      });

      test('noise reduction, leading room tone as the profile', () {
        final Samples out = noise.reduce(input, rate, reductionDb: 22, sensitivity: 1.5, profileSeconds: 0.25);
        _expectClose(out, load('noise_profile'));
      });

      test('silence trim', () {
        final (int start, int end) = trimmer.keptRange(input, rate, paddingSeconds: 0.05);
        expect(<int>[start, end], info['kept_range']);
        _expectClose(trimmer.cut(input, rate, start: start, end: end), load('trim'));
      });

      final Map<String, dynamic> chains = info['chains'] as Map<String, dynamic>;
      for (final String key in <String>['natural', 'studio', 'loudness']) {
        test('whole 0.1 chain, $key preset of the Python engine', () {
          final Map<String, dynamic> chain = chains[key] as Map<String, dynamic>;
          final EnhanceSettings settings = _settingsOf(chain['settings'] as Map<String, dynamic>);
          final List<AudioProgress> steps = <AudioProgress>[];
          final EnhanceResult result = enhancer.enhance(
            PcmAudio(samples: input, sampleRate: rate),
            settings: settings,
            onProgress: steps.add,
          );
          expect(<int>[result.keptFrom, result.keptTo], chain['kept']);
          expect(steps.map((AudioProgress p) => p.step).toSet(), hasLength(steps.first.steps));
          _expectClose(result.audio.samples, load('chain_$key'), tolerance: 1e-5);
        });
      }

      test('the classic preset is the 0.1 natural chain', () {
        final Map<String, dynamic> natural = chains['natural'] as Map<String, dynamic>;
        _expectSameSettings(EnhancePreset.classic.settings, _settingsOf(natural['settings'] as Map<String, dynamic>));
      });

      // 0.2 steps, against tool/reference_extras.py
      if (channels == 2) {
        test('stereo alignment', () {
          final Samples delayed = load('input_delayed');
          expect(const StereoAligner().lagOf(delayed, rate), -13);
          _expectClose(const StereoAligner().align(delayed, rate), load('align'));
        });
      }

      test('tone balance correction and filter', () {
        final (List<double> _, Float64List correction) = const ToneBalancer().correction(input, rate);
        final List<dynamic> expected = info['tone_correction'] as List<dynamic>;
        expect(correction.length, expected.length);
        for (int i = 0; i < correction.length; i++) {
          expect(correction[i], closeTo((expected[i] as num).toDouble(), 1e-6), reason: 'band $i');
        }
        _expectClose(const ToneBalancer().balance(input, rate), load('auto_eq'), tolerance: 1e-5);
      });

      test('expander', () {
        _expectClose(dynamics.expand(input, rate, belowDb: 20, ratio: 2, floorDb: -12), load('expand'));
      });

      final Map<String, dynamic> chainsV2 = info['chains_v2'] as Map<String, dynamic>;
      for (final EnhancePreset preset in <EnhancePreset>[EnhancePreset.natural, EnhancePreset.studio]) {
        test('whole 0.2 chain, ${preset.name} preset', () {
          final Map<String, dynamic> chain = chainsV2[preset.name] as Map<String, dynamic>;
          final Map<String, dynamic> extras = chain['extras'] as Map<String, dynamic>;
          final EnhanceSettings settings = _settingsOf(chain['settings'] as Map<String, dynamic>).copyWith(
            alignStereo: (extras['align'] as num) > 0,
            toneMaxBoostDb: (extras['max_boost'] as num).toDouble(),
            toneMaxCutDb: (extras['max_cut'] as num).toDouble(),
            expanderBelowDb: (extras['below'] as num).toDouble(),
            expanderRatio: (extras['ratio'] as num).toDouble(),
            expanderFloorDb: (extras['floor'] as num).toDouble(),
            // The reference keeps the 0.1 cap of 30 dB; these signals need far less gain.
            maxGainDb: preset.settings.maxGainDb,
          );
          _expectSameSettings(
            preset.settings.copyWith(
              trimSilence: settings.trimSilence,
              trimPaddingSeconds: settings.trimPaddingSeconds,
            ),
            settings,
          );
          final EnhanceResult result = enhancer.enhance(
            PcmAudio(samples: input, sampleRate: rate),
            settings: settings,
          );
          expect(<int>[result.keptFrom, result.keptTo], chain['kept']);
          _expectClose(result.audio.samples, load('chain_v2_${preset.name}'), tolerance: 1e-5);
        });
      }
    });
  }

  test('WAV round trip keeps 24-bit precision', () {
    final Samples samples = <Float64List>[
      Float64List.fromList(<double>[0, 0.5, -0.5, 0.999, -1, 1e-7]),
      Float64List.fromList(<double>[0.25, -0.25, 0.1, -0.1, 0.0001, 2]),
    ];
    final PcmAudio decoded = WavCodec.decode(WavCodec.encode24(PcmAudio(samples: samples, sampleRate: 44100)));
    expect(decoded.sampleRate, 44100);
    expect(decoded.channels, 2);
    expect(decoded.samples[1][5], closeTo(1 - 1 / 8388608, 1e-12));
    for (int c = 0; c < 2; c++) {
      for (int i = 0; i < 5; i++) {
        expect(decoded.samples[c][i], closeTo(samples[c][i], 1 / 8388608));
      }
    }
  });
}

Samples _load(String path, int channels) {
  final Float32List all = File(path).readAsBytesSync().buffer.asFloat32List();
  final int frames = all.length ~/ channels;
  return <Float64List>[
    for (int c = 0; c < channels; c++) Float64List.fromList(all.sublist(c * frames, (c + 1) * frames)),
  ];
}

/// Settings from the snake_case dictionary of the Python engine; the 0.2 steps are off.
EnhanceSettings _settingsOf(Map<String, dynamic> s) {
  double v(String key) => (s[key] as num).toDouble();
  return EnhanceSettings(
    alignStereo: false,
    toneMaxBoostDb: 0,
    toneMaxCutDb: 0,
    expanderRatio: 1,
    maxGainDb: 30,
    highPassHz: v('high_pass_hz'),
    noiseReductionDb: v('noise_reduction_db'),
    noiseSensitivity: v('noise_sensitivity'),
    noiseProfileSeconds: v('noise_profile_seconds'),
    mudCutDb: v('mud_cut_db'),
    mudHz: v('mud_hz'),
    presenceDb: v('presence_db'),
    presenceHz: v('presence_hz'),
    airDb: v('air_db'),
    airHz: v('air_hz'),
    deEssDb: v('de_ess_db'),
    compressionRatio: v('compression_ratio'),
    compressionThresholdDb: v('compression_threshold_db'),
    compressionAttackSeconds: v('compression_attack_s'),
    compressionReleaseSeconds: v('compression_release_s'),
    targetLufs: v('target_lufs'),
    truePeakDb: v('true_peak_db'),
    limiterReleaseSeconds: v('limiter_release_s'),
    trimSilence: v('trim_silence') > 0,
    trimPaddingSeconds: v('trim_padding_s'),
  );
}

void _expectSameSettings(EnhanceSettings a, EnhanceSettings b) {
  List<Object?> values(EnhanceSettings s) => <Object?>[
    s.alignStereo, s.toneMaxBoostDb, s.toneMaxCutDb, s.toneCurve, s.highPassHz, s.noiseReductionDb, //
    s.noiseSensitivity, s.noiseProfileSeconds, s.mudCutDb, s.mudHz, s.presenceDb, s.presenceHz, s.airDb, s.airHz,
    s.deEssDb, s.compressionRatio, s.compressionThresholdDb, s.compressionAttackSeconds,
    s.compressionReleaseSeconds, s.expanderRatio, s.expanderBelowDb, s.expanderFloorDb, s.targetLufs, s.maxGainDb,
    s.truePeakDb, s.limiterReleaseSeconds, s.trimSilence, s.trimPaddingSeconds,
  ];
  expect(values(a), values(b));
}

double _number(dynamic value) => switch (value) {
  'inf' => double.infinity,
  '-inf' => double.negativeInfinity,
  final num n => n.toDouble(),
  _ => throw ArgumentError.value(value),
};

void _expectClose(Samples actual, Samples expected, {double tolerance = _tolerance}) {
  expect(actual.length, expected.length, reason: 'channels');
  for (int c = 0; c < actual.length; c++) {
    expect(actual[c].length, expected[c].length, reason: 'length of channel $c');
    double worst = 0;
    int at = 0;
    for (int i = 0; i < actual[c].length; i++) {
      final double error = (actual[c][i] - expected[c][i]).abs();
      if (error > worst) {
        worst = error;
        at = i;
      }
    }
    expect(
      worst,
      lessThanOrEqualTo(math.max(tolerance, expected[c][at].abs() * 1e-6)),
      reason: 'channel $c, sample $at: ${actual[c][at]} vs ${expected[c][at]}',
    );
  }
}
