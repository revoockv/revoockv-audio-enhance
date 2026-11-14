import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_audio.dart';
import '../fft/real_fft.dart';
import '../filters/windows.dart';
import '../math/numeric.dart';

/// Spectral-gate noise reduction with a learned noise profile.
///
/// Lowers every time-frequency bin that is no louder than the room noise. The noise profile
/// (median and spread of the noise level in every frequency bin) comes from the leading room
/// tone when the caller says how long it is, otherwise from the quietest 3 % of the recording;
/// digital silence is never part of it. A bin above the profile passes, a bin inside it is
/// lowered by the reduction amount, with a soft 6 dB transition. The gain mask is smoothed over
/// time and frequency so that steady tones stay steady and no "musical noise" chirps appear.
///
/// The STFT is processed in batches of frames, so memory stays small for long takes.
final class NoiseReducer {
  static const int _fftSizeHighRate = 2048;
  static const int _fftSizeLowRate = 1024;
  static const int _highRate = 32000;
  static const int _hopDivisor = 4;
  static const int _batchFrames = 512;
  static const int _smoothFrames = 5;
  static const int _smoothBins = 3;
  static const double _transitionDb = 6.0;
  static const double _quietShare = 0.03;
  static const double _silenceDb = -100.0;
  static const double _quartileLow = 25;
  static const double _quartileHigh = 75;
  static const double _iqrToSpread = 1.349;
  static const int _minProfileFrames = 8;
  static const int _maxProfileFrames = 4000;
  static const double _epsilon = 1e-12;

  /// Creates a new [NoiseReducer].
  const NoiseReducer();

  /// [samples] with the steady noise lowered by [reductionDb].
  ///
  /// [sensitivity] is how many spreads above the median noise level still count as noise;
  /// [profileSeconds] of leading room tone are the noise profile (0 = find the quietest parts).
  Samples reduce(
    Samples samples,
    int sampleRate, {
    required double reductionDb,
    required double sensitivity,
    required double profileSeconds,
  }) {
    if (reductionDb <= 0) return samples;
    final int size = sampleRate >= _highRate ? _fftSizeHighRate : _fftSizeLowRate;
    final int profileFrames = Numeric.roundHalfEven(profileSeconds * sampleRate);
    final RealFft fft = RealFft(size);
    final Float64List window = Windows.hannPeriodic(size);
    return <Float64List>[
      for (final Float64List channel in samples)
        _reduceChannel(
          channel,
          fft: fft,
          window: window,
          reductionDb: reductionDb,
          sensitivity: sensitivity,
          profileFrames: profileFrames,
        ),
    ];
  }

  Float64List _reduceChannel(
    Float64List channel, {
    required RealFft fft,
    required Float64List window,
    required double reductionDb,
    required double sensitivity,
    required int profileFrames,
  }) {
    final int size = fft.size;
    final int bins = fft.bins;
    final int hop = size ~/ _hopDivisor;
    final int length = channel.length;
    final int tail = size + (-(length + size)) % hop;
    final Float64List padded = Float64List(size + length + tail)..setRange(size, size + length, channel);
    final int count = (padded.length - size) ~/ hop + 1;

    final (Float64List meanDb, Float64List spreadDb) = _noiseProfile(
      padded,
      count,
      fft: fft,
      window: window,
      length: length,
      profileFrames: profileFrames,
    );
    final Float64List threshold = Float64List(bins);
    for (int k = 0; k < bins; k++) {
      threshold[k] = meanDb[k] + sensitivity * spreadDb[k];
    }

    final Float64List output = Float64List(padded.length);
    // 10 ** (-(1 - keep) * reductionDb / 20) as exp(lowering * (1 - keep)).
    final double lowering = -reductionDb * math.ln10 / 20;
    final double closedGain = math.exp(lowering);
    // The mask is 0 or 1 outside a 6 dB band around the threshold. Squared magnitudes compared
    // with these bounds (a hair inside them) skip the logarithm for almost every bin.
    final Float64List closedBelow = Float64List(bins);
    final Float64List openAbove = Float64List(bins);
    for (int k = 0; k < bins; k++) {
      final double below = Numeric.dbToAmplitude(threshold[k] - _transitionDb / 2) * (1 - 1e-9) - _epsilon;
      final double above = Numeric.dbToAmplitude(threshold[k] + _transitionDb / 2) * (1 + 1e-9) - _epsilon;
      closedBelow[k] = below > 0 ? below * below : -1;
      openAbove[k] = above > 0 ? above * above : 0;
    }
    const int context = _smoothFrames;
    for (int first = 0; first < count; first += _batchFrames) {
      final int last = math.min(count, first + _batchFrames);
      final int low = math.max(0, first - context);
      final int high = math.min(count, last + context);
      final int rows = high - low;
      final List<Float64x2List> spectra = _spectra(fft, padded, <int>[
        for (int f = low; f < high; f++) f * hop,
      ], window);
      final Float64List keep = Float64List(rows * bins);
      for (int r = 0; r < rows; r++) {
        final Float64x2List spectrum = spectra[r];
        final int row = r * bins;
        for (int k = 0; k < bins; k++) {
          final Float64x2 bin = spectrum[k];
          final double power = bin.x * bin.x + bin.y * bin.y;
          if (power <= closedBelow[k]) continue; // keep 0
          if (power >= openAbove[k]) {
            keep[row + k] = 1.0;
            continue;
          }
          final double levelDb = Numeric.amplitudeToDb(math.sqrt(power) + _epsilon);
          final double value = (levelDb - threshold[k]) / _transitionDb + 0.5;
          keep[row + k] = value < 0 ? 0.0 : (value > 1 ? 1.0 : value);
        }
      }
      final Float64List smoothed = _uniformFilter(keep, rows, bins);
      for (int f = first; f < last; f++) {
        final int r = f - low;
        final Float64x2List spectrum = spectra[r];
        for (int k = 0; k < bins; k++) {
          final double open = smoothed[r * bins + k];
          if (open == 1.0) continue;
          spectrum[k] = spectrum[k].scale(open == 0.0 ? closedGain : math.exp(lowering * (1.0 - open)));
        }
      }
      // Two frames per inverse FFT.
      for (int f = first; f < last; f += 2) {
        final bool pair = f + 1 < last;
        fft.inverseWindowedPairAdd(
          spectra[f - low],
          pair ? spectra[f + 1 - low] : null,
          window,
          output,
          f * hop,
          (f + 1) * hop,
        );
      }
    }

    final Float64List folded = Float64List(hop);
    for (int i = 0; i < size; i++) {
      folded[i % hop] += window[i] * window[i];
    }
    final Float64List result = Float64List(length);
    for (int i = 0; i < length; i++) {
      result[i] = output[size + i] / folded[i % hop];
    }
    return result;
  }

  (Float64List, Float64List) _noiseProfile(
    Float64List padded,
    int count, {
    required RealFft fft,
    required Float64List window,
    required int length,
    required int profileFrames,
  }) {
    final int size = fft.size;
    final int hop = size ~/ _hopDivisor;
    final Float64List squares = Float64List(padded.length + 1);
    for (int i = 0; i < padded.length; i++) {
      squares[i + 1] = squares[i] + padded[i] * padded[i];
    }
    final Float64List energy = Float64List(count);
    final double silence = size * math.pow(10, _silenceDb / 10).toDouble();
    final List<int> allInside = <int>[];
    final List<int> leading = <int>[];
    for (int f = 0; f < count; f++) {
      final int start = f * hop;
      energy[f] = squares[start + size] - squares[start];
      // Digital silence (the recorder starting up) is no room noise: it would drag the profile
      // down and widen its spread until the gate lowers the voice instead of the noise.
      final bool inside = start >= size && start + size <= size + length && energy[f] > silence;
      if (!inside) continue;
      allInside.add(f);
      if (start + size <= size + profileFrames) leading.add(f);
    }

    List<int> chosen = leading;
    if (chosen.length < _minProfileFrames ||
        (allInside.isNotEmpty &&
            _mean(energy, chosen) > Numeric.median(<double>[for (final int f in allInside) energy[f]]))) {
      chosen = _quietest(energy, allInside);
    }
    if (chosen.isEmpty) chosen = List<int>.generate(count, (int f) => f);
    if (chosen.length > _maxProfileFrames) {
      final Float64List picks = Numeric.linspace(0, chosen.length - 1.0, _maxProfileFrames);
      chosen = <int>[for (final double pick in picks) chosen[pick.toInt()]];
    }

    final List<Float64List> perBin = List<Float64List>.generate(fft.bins, (_) => Float64List(chosen.length));
    final List<Float64x2List> spectra = _spectra(fft, padded, <int>[for (final int f in chosen) f * hop], window);
    for (int r = 0; r < chosen.length; r++) {
      final Float64List magnitudes = RealFft.magnitudes(spectra[r]);
      for (int k = 0; k < fft.bins; k++) {
        perBin[k][r] = Numeric.amplitudeToDb(magnitudes[k] + _epsilon);
      }
    }
    final Float64List middle = Float64List(fft.bins);
    final Float64List spread = Float64List(fft.bins);
    for (int k = 0; k < fft.bins; k++) {
      // Median and quartile spread: a few loud frames among the quiet ones do not move them.
      final Float64List sorted = perBin[k]..sort();
      middle[k] = Numeric.percentileOfSorted(sorted, 50);
      spread[k] =
          (Numeric.percentileOfSorted(sorted, _quartileHigh) - Numeric.percentileOfSorted(sorted, _quartileLow)) /
          _iqrToSpread;
    }
    return (middle, spread);
  }

  List<int> _quietest(Float64List energy, List<int> candidates) {
    if (candidates.isEmpty) return candidates;
    final int count = math.max(_minProfileFrames, (candidates.length * _quietShare).toInt());
    final List<int> order = List<int>.generate(candidates.length, (int i) => i);
    // A stable sort by energy, like numpy.argsort(kind="stable").
    _stableSort(order, (int a, int b) => energy[candidates[a]].compareTo(energy[candidates[b]]));
    return <int>[for (final int i in order.take(count)) candidates[i]]..sort();
  }

  static double _mean(Float64List values, List<int> indexes) {
    double sum = 0;
    for (final int i in indexes) {
      sum += values[i];
    }
    return sum / indexes.length;
  }

  /// Half spectra of the windowed frames starting at [starts], two frames per FFT.
  static List<Float64x2List> _spectra(RealFft fft, Float64List padded, List<int> starts, Float64List window) {
    final List<Float64x2List> out = <Float64x2List>[for (int i = 0; i < starts.length; i++) Float64x2List(fft.bins)];
    final Float64x2List spare = Float64x2List(fft.bins);
    for (int i = 0; i < starts.length; i += 2) {
      final bool pair = i + 1 < starts.length;
      fft.forwardWindowedPair(padded, window, starts[i], pair ? starts[i + 1] : -1, out[i], pair ? out[i + 1] : spare);
    }
    return out;
  }

  /// `scipy.ndimage.uniform_filter(values, size=(5, 3), mode="nearest")` over a rows x cols grid.
  static Float64List _uniformFilter(Float64List values, int rows, int cols) {
    const int halfRows = _smoothFrames ~/ 2;
    const int halfCols = _smoothBins ~/ 2;
    final Float64List alongRows = Float64List(values.length);
    for (int r = 0; r < rows; r++) {
      final int out = r * cols;
      for (int d = -halfRows; d <= halfRows; d++) {
        final int source = r + d;
        final int from = (source < 0 ? 0 : (source >= rows ? rows - 1 : source)) * cols;
        for (int c = 0; c < cols; c++) {
          alongRows[out + c] += values[from + c];
        }
      }
      for (int c = 0; c < cols; c++) {
        alongRows[out + c] /= _smoothFrames;
      }
    }
    final Float64List result = Float64List(values.length);
    for (int r = 0; r < rows; r++) {
      final int row = r * cols;
      for (int c = 0; c < cols; c++) {
        double sum = 0;
        for (int d = -halfCols; d <= halfCols; d++) {
          final int source = c + d;
          sum += alongRows[row + (source < 0 ? 0 : (source >= cols ? cols - 1 : source))];
        }
        result[row + c] = sum / _smoothBins;
      }
    }
    return result;
  }

  static void _stableSort(List<int> list, int Function(int, int) compare) {
    if (list.length < 2) return;
    final List<int> buffer = List<int>.filled(list.length, 0);
    for (int width = 1; width < list.length; width *= 2) {
      for (int left = 0; left < list.length; left += 2 * width) {
        final int middle = math.min(left + width, list.length);
        final int right = math.min(left + 2 * width, list.length);
        int i = left, j = middle, k = left;
        while (i < middle && j < right) {
          buffer[k++] = compare(list[j], list[i]) < 0 ? list[j++] : list[i++];
        }
        while (i < middle) {
          buffer[k++] = list[i++];
        }
        while (j < right) {
          buffer[k++] = list[j++];
        }
      }
      list.setAll(0, buffer);
    }
  }
}
