# revoockv_audio_enhance

Pure-Dart vocal enhancement — no native code, no FFI, no Python. It runs the same on Android,
iOS, macOS, Windows, Linux and the web.

This package does not invent new DSP. It **groups well-known audio-cleanup tools into one
chain** and ports each of them to Dart from the libraries where they come from (SciPy, NumPy,
libebur128, the RBJ cookbook — see [Based on](#based-on)). Every tool can also be used on its
own.

## The chain

| Step | Tool | What it does |
|---|---|---|
| 1 | `BiquadFilters.highPass` | 2nd-order Butterworth high-pass: removes rumble and handling noise |
| 2 | `NoiseReducer` | spectral gate with a learned noise profile (STFT, Hann, 75 % overlap) |
| 3 | `BiquadFilters.equalize` | peaking "mud" cut, "presence" boost, "air" high shelf |
| 4 | `DynamicsProcessor.deEss` | lowers the 5–9 kHz band while it dominates ("s", "sh") |
| 5 | `DynamicsProcessor.compress` | soft-knee compressor, threshold relative to the loudness |
| 6 | `LoudnessMeter` + gain | normalises to a target integrated loudness (ITU-R BS.1770, LUFS) |
| 7 | `DynamicsProcessor.limit` | look-ahead true-peak limiter (4× oversampled peaks) |
| 8 | `SilenceTrimmer` | optional: cuts the silence before and after the singing |

Plus `LoudnessMeter.measure` (loudness, true peak, clipping, noise floor, SNR), `WavCodec`
(8/16/24/32-bit PCM and float WAV in, 24-bit PCM out) and `RealFft`, a thin real-input wrapper
over [fftea](https://pub.dev/packages/fftea) with a "two real FFTs for one complex FFT" fast path.

## Usage

```dart
import 'package:revoockv_audio_enhance/io.dart';
import 'package:revoockv_audio_enhance/revoockv_audio_enhance.dart';

Future<void> main() async {
  final PcmAudio take = await WavFile.read('take.wav');
  final EnhanceResult result = VocalEnhancer().enhance(
    take,
    settings: EnhancePreset.studio.settings.copyWith(trimSilence: true),
    onProgress: (EnhanceProgress p) => print('${(p.fraction * 100).round()} % ${p.label}'),
  );
  print('${result.before.integratedLufs} → ${result.after.integratedLufs} LUFS');
  await WavFile.write('take_enhanced.wav', result.audio);
}
```

`WavFile` needs `dart:io`; on the web decode and encode bytes with `WavCodec` instead.

The work is synchronous and CPU-bound. In a Flutter app run it off the UI thread:

```dart
final EnhanceResult result = await Isolate.run(() => VocalEnhancer().enhance(take));
```

### Presets

- `EnhancePreset.natural` — gentle cleanup, keeps the room and the dynamics (the defaults);
- `EnhancePreset.studio` — stronger noise reduction, more presence, tighter compression;
- `EnhancePreset.loudnessOnly` — only loudness and limiting, to compare with the raw take.

Any value can be changed with `copyWith`; a step whose amount is 0 is skipped.

## Accuracy

The port is checked number for number against the reference Python implementation (NumPy /
SciPy): every tool and the whole chain, mono 48 kHz and stereo 44.1 kHz, match to about
1e-6 of full scale (the precision of the stored float32 references). `tool/make_fixtures.py`
regenerates the references.

## Performance

On a 48 s mono voice recording (Apple M-series, `dart compile exe`) the whole chain takes about
as long as the NumPy/SciPy version (~0.8–1.3 s each). The hot loops use `Float64x2` SIMD, the
true-peak search skips blocks that provably cannot reach the level in question, and the STFT
packs two real frames into each complex FFT.

## Based on

| Part | Ported from / follows | Licence |
|---|---|---|
| Butterworth design (`butter`, `buttap`, `lp2hp_zpk`, `lp2bp_zpk`, `bilinear_zpk`, `zpk2sos`), `sosfilt`, `sosfiltfilt`, `sosfilt_zi`, `lfilter_zi`, `resample_poly`, `firwin`, `windows.kaiser`, `get_window('hann')` | [SciPy](https://github.com/scipy/scipy) `scipy.signal` | BSD-3-Clause |
| `uniform_filter` (mask smoothing) | [SciPy](https://github.com/scipy/scipy) `scipy.ndimage` | BSD-3-Clause |
| WAV decoding rules | [SciPy](https://github.com/scipy/scipy) `scipy.io.wavfile` | BSD-3-Clause |
| `rfft`/`irfft` semantics, `percentile`, `interp`, `linspace`, `argsort(kind="stable")` | [NumPy](https://github.com/numpy/numpy) | BSD-3-Clause |
| K-weighting coefficients for any sample rate | [libebur128](https://github.com/jiixyj/libebur128) | MIT |
| Integrated loudness, gating, true peak | [ITU-R BS.1770](https://www.itu.int/rec/R-REC-BS.1770) | standard |
| Peaking EQ and high shelf | [RBJ Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) | public |
| Spectral gating noise reduction | the technique popularised by [noisereduce](https://github.com/timsainb/noisereduce) | MIT |
| FFT | [fftea](https://github.com/liamappelbe/fftea) (dependency, wrapped by `RealFft`) | Apache-2.0 |

The code is a re-implementation in Dart, not a copy of these projects' sources; the constants and
formulas they publish are used with attribution. See [NOTICE.md](NOTICE.md).

## Licence

BSD-3-Clause — see [LICENSE](LICENSE). It is compatible with every licence listed above.
