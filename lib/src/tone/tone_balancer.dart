import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import '../filters/fir_filter.dart';
import '../filters/windows.dart';
import '../math/numeric.dart';
import '../math/spectral.dart';

/// A target long-term spectrum: a level in dB for every third-octave band centre.
///
/// Only the shape matters; the overall level is set by the loudness step.
final class ToneCurve {
  /// Band centres in Hz, ascending.
  final List<double> centres;

  /// Level of every band in dB.
  final List<double> levels;

  /// Creates a new [ToneCurve].
  ToneCurve({required this.centres, required this.levels}) {
    if (centres.length != levels.length || centres.length < 3) {
      throw ArgumentError('a tone curve needs as many levels as centres (at least 3)');
    }
  }

  /// The third-octave centres from 63 Hz to 16 kHz.
  static const List<double> thirdOctaves = <double>[
    63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, //
    3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000,
  ];

  /// A natural voice-and-guitar balance: the smoothed long-term spectrum of a reference
  /// recording, about −4 dB per octave above 400 Hz.
  static final ToneCurve balanced = ToneCurve(
    centres: thirdOctaves,
    levels: const <double>[
      -27.0, -20.2, -13.1, -9.3, -8.6, -7.6, -4.2, -0.5, 0.0, -1.5, -4.1, -6.1, -8.7, -10.6, //
      -12.0, -12.7, -13.6, -14.9, -16.5, -18.0, -19.2, -20.2, -20.4, -20.0, -19.1,
    ],
  );
}

/// Automatic tone balance (auto-EQ): measures the long-term spectrum of a recording and pulls it
/// towards a [ToneCurve] with a linear-phase FIR filter.
///
/// The correction is smoothed over neighbouring bands, limited to a boost and a cut, and never
/// boosts below 150 Hz (a voice has nothing there but rumble). Only the louder 60 % of 50 ms
/// blocks are measured, so pauses and room noise do not count.
final class ToneBalancer {
  static const double _blockSeconds = 0.05;
  static const double _voicedPercentile = 40;
  static const int _welchSegment = 8192;
  static const int _firTaps = 4097;
  static const double _noBoostBelowHz = 150;
  static const double _levelLowHz = 200;
  static const double _levelHighHz = 4000;
  static const double _maxBand = 0.45;
  static const double _powerFloor = 1e-30;
  static final double _bandEdge = math.pow(2, 1 / 6).toDouble();

  /// Creates a new [ToneBalancer].
  const ToneBalancer();

  /// [samples] pulled towards [curve], by at most [maxBoostDb] up and [maxCutDb] down.
  Samples balance(Samples samples, int sampleRate, {ToneCurve? curve, double maxBoostDb = 12, double maxCutDb = 12}) {
    if (maxBoostDb <= 0 && maxCutDb <= 0) return samples;
    final (List<double> centres, Float64List correction) = this.correction(
      samples,
      sampleRate,
      curve: curve,
      maxBoostDb: maxBoostDb,
      maxCutDb: maxCutDb,
    );
    final List<double> freqs = <double>[0, ...centres, sampleRate / 2];
    final List<double> gains = <double>[
      for (final double db in <double>[correction.first, ...correction, correction.last]) Numeric.dbToAmplitude(db),
    ];
    final FirFilter filter = FirFilter(Windows.firwin2(_firTaps, freqs, gains, sampleRate.toDouble()));
    return <Float64List>[for (final Float64List channel in samples) filter.filterSame(channel)];
  }

  /// The band centres in use (below 45 % of [sampleRate]) and the correction in dB of each.
  (List<double>, Float64List) correction(
    Samples samples,
    int sampleRate, {
    ToneCurve? curve,
    double maxBoostDb = 12,
    double maxCutDb = 12,
  }) {
    final ToneCurve target = curve ?? ToneCurve.balanced;
    final List<int> used = <int>[
      for (int i = 0; i < target.centres.length; i++)
        if (target.centres[i] < _maxBand * sampleRate) i,
    ];
    final List<double> centres = <double>[for (final int i in used) target.centres[i]];
    final Float64List bands = bandLevels(samples, sampleRate, centres);
    final int n = centres.length;
    final Float64List raw = Float64List(n);
    for (int b = 0; b < n; b++) {
      raw[b] = target.levels[used[b]] - bands[b];
    }
    final double level = Numeric.median(<double>[
      for (int b = 0; b < n; b++)
        if (centres[b] >= _levelLowHz && centres[b] <= _levelHighHz) raw[b],
    ]);
    final Float64List out = Float64List(n);
    for (int b = 0; b < n; b++) {
      final double previous = raw[math.max(0, b - 1)] - level;
      final double next = raw[math.min(n - 1, b + 1)] - level;
      double value = 0.25 * previous + 0.5 * (raw[b] - level) + 0.25 * next;
      value = value.clamp(-maxCutDb, maxBoostDb).toDouble();
      if (centres[b] < _noBoostBelowHz) value = math.min(value, 0);
      out[b] = value;
    }
    return (centres, out);
  }

  /// Long-term level (dB) of every third-octave band around [centres], over the louder 60 % of
  /// 50 ms blocks of the channel average.
  static Float64List bandLevels(Samples samples, int sampleRate, List<double> centres) {
    final int frames = SampleOps.frames(samples);
    final Float64List mono = Float64List(frames);
    for (final Float64List channel in samples) {
      for (int i = 0; i < frames; i++) {
        mono[i] += channel[i];
      }
    }
    for (int i = 0; i < frames; i++) {
      mono[i] /= samples.length;
    }
    final int block = (_blockSeconds * sampleRate).toInt();
    final int blocks = frames ~/ block;
    final Float64List power = Float64List(blocks);
    for (int b = 0; b < blocks; b++) {
      double sum = 0;
      for (int i = b * block; i < (b + 1) * block; i++) {
        sum += mono[i] * mono[i];
      }
      power[b] = sum / block;
    }
    final double threshold = Numeric.percentile(power, _voicedPercentile);
    final List<int> kept = <int>[
      for (int b = 0; b < blocks; b++)
        if (power[b] >= threshold) b,
    ];
    final Float64List voiced = Float64List(kept.length * block);
    for (int k = 0; k < kept.length; k++) {
      voiced.setRange(k * block, (k + 1) * block, mono, kept[k] * block);
    }
    final (Float64List freqs, Float64List psd) = Spectral.welch(voiced, sampleRate, segment: _welchSegment);
    return Float64List.fromList(<double>[
      for (final double centre in centres)
        () {
          double sum = 0;
          for (int k = 0; k < freqs.length; k++) {
            if (freqs[k] >= centre / _bandEdge && freqs[k] < centre * _bandEdge) sum += psd[k];
          }
          return Numeric.powerToDb(sum + _powerFloor);
        }(),
    ]);
  }
}
