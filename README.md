# revoockv_audio_enhance

Make a voice recording sound clean, clear and evenly loud — in pure Dart, with no native code, no
FFI and no Python. It runs the same on Android, iOS, macOS, Windows, Linux and the web.

This package does not invent new DSP. It **groups well-known audio-cleanup tools into one
chain** and ports each of them to Dart from the libraries where they come from (SciPy, NumPy,
libebur128, the RBJ cookbook — see [Based on](#based-on)). Use the whole chain in one call, or
any tool on its own.

- [Is it for me?](#is-it-for-me)
- [Quick start](#quick-start)
- [Use cases](#use-cases)
- [The chain](#the-chain) · [Settings](#settings) · [Presets](#presets)
- [Limits](#limits) · [Accuracy](#accuracy) · [Performance](#performance)
- [Based on](#based-on) · [Licence](#licence)

## Is it for me?

**Yes, if you have a recorded file of a voice** — a sung take, a podcast, a voice memo, a
lesson, an interview — and want it to sound better before you play, share or export it:

- the hum, rumble and steady room noise (fan, fridge, hiss) are lowered;
- the voice gets clearer: less boom, more presence and air, softer "s" sounds;
- quiet and loud phrases come closer together;
- the file ends up at a standard loudness (−14 LUFS by default, like streaming services) and
  never clips;
- the silence before and after the voice can be cut away.

It also **measures** a recording (loudness, true peak, clipping, noise floor, signal-to-noise),
so an app can tell the user "too quiet", "clipped" or "noisy room".

**Not for:** real-time processing of a live microphone (the tools need the whole file — the noise
profile and the loudness are measured over all of it), music mastering of full mixes, or
AI-style voice isolation (it removes steady noise, not music or other voices).

## Quick start

```yaml
dependencies:
  revoockv_audio_enhance: ^0.1.0
```

```dart
import 'package:revoockv_audio_enhance/io.dart';
import 'package:revoockv_audio_enhance/revoockv_audio_enhance.dart';

Future<void> main() async {
  final PcmAudio take = await WavFile.read('take.wav');
  final EnhanceResult result = VocalEnhancer().enhance(take);
  await WavFile.write('take_enhanced.wav', result.audio);
  print('${result.before.integratedLufs} → ${result.after.integratedLufs} LUFS');
}
```

`package:revoockv_audio_enhance/io.dart` reads and writes files and needs `dart:io`. Everything
else works on bytes and lists, so it also runs on the web.

## Use cases

### 1. Clean up a recorded vocal take (the main one)

A karaoke, cover or practice app records a WAV and offers an "Enhance" button.

```dart
final EnhanceResult result = VocalEnhancer().enhance(
  take,
  settings: EnhancePreset.studio.settings.copyWith(trimSilence: true),
);
// result.audio — the enhanced take; result.keptFrom / keptTo — where it was cut in the original
// (samples), to keep a backing track or lyrics in sync.
```

### 2. Run it in a Flutter app without freezing the UI, with a progress bar

The work is synchronous and CPU-bound, so run it in another isolate. Progress comes back through
a port:

```dart
import 'dart:isolate';

Future<EnhanceResult> enhanceInBackground(PcmAudio take, void Function(double) onProgress) async {
  final ReceivePort progress = ReceivePort();
  progress.listen((Object? fraction) => onProgress(fraction! as double));
  final SendPort port = progress.sendPort;
  try {
    return await Isolate.run(
      () => VocalEnhancer().enhance(take, onProgress: (EnhanceProgress p) => port.send(p.fraction)),
    );
  } finally {
    progress.close();
  }
}
```

`EnhanceProgress.label` names the step ("Reducing noise") if you want to show it.

### 3. Check the microphone or the input level before recording

Record a few seconds, then measure. `RecordingAnalysis` has ready-made verdicts:

```dart
final RecordingAnalysis check = VocalEnhancer().analyze(testClip);
if (check.isClipped) print('Too loud — move away or lower the input gain');
if (check.isTooQuiet) print('Too quiet — come closer to the microphone');
if (check.isNoisy) print('Noisy room (SNR ${check.signalToNoiseDb.toStringAsFixed(0)} dB)');
```

It also helps to spot a dead input: a take whose `truePeakDb` is `-infinity` recorded only
zeros.

### 4. Only make the loudness standard (podcasts, voice-overs, A/B comparison)

No colouring, just normalisation and a true-peak limiter. Pick the target of your platform:

```dart
final EnhanceResult result = VocalEnhancer().enhance(
  episode,
  settings: EnhancePreset.loudnessOnly.settings.copyWith(targetLufs: -16, truePeakDb: -1.5),
);
```

The same preset gives a loudness-matched copy of the raw take, so "before / after" can be
compared fairly — otherwise the louder version always seems better.

### 5. Remove steady noise with a known room tone

If the user stays silent for the first second or two, use that as the noise profile; it is more
precise than the automatic search for the quietest parts:

```dart
final EnhanceSettings settings = const EnhanceSettings().copyWith(
  noiseProfileSeconds: 1.5,
  noiseReductionDb: 20,
);
```

Or call the tool alone:

```dart
final Samples cleaned = const NoiseReducer().reduce(
  take.samples,
  take.sampleRate,
  reductionDb: 16,
  sensitivity: 1.5,
  profileSeconds: 0, // 0 = find the quietest 3 % of the recording
);
```

### 6. Cut the silence around a voice

```dart
const SilenceTrimmer trimmer = SilenceTrimmer();
final (int start, int end) = trimmer.keptRange(take.samples, take.sampleRate, paddingSeconds: 0.3);
final Samples trimmed = trimmer.cut(take.samples, take.sampleRate, start: start, end: end);
```

### 7. Use single tools in your own chain

Every step is a plain class; combine them in any order:

```dart
const BiquadFilters filters = BiquadFilters();
final LoudnessMeter meter = LoudnessMeter(filters);
final DynamicsProcessor dynamics = DynamicsProcessor(filters: filters, loudness: meter);

Samples s = filters.highPass(take.samples, take.sampleRate, cornerHz: 100);
s = filters.band(s, take.sampleRate, lowHz: 300, highHz: 3400); // telephone sound, zero phase
s = dynamics.compress(s, take.sampleRate, ratio: 4, thresholdDb: -6, attackSeconds: 0.005, releaseSeconds: 0.1);
s = dynamics.limit(s, take.sampleRate, ceilingDb: -1, releaseSeconds: 0.08);
print('${meter.integratedLufs(s, take.sampleRate)} LUFS, true peak ${meter.truePeak(s)}');
```

Lower-level pieces are public too: `Butterworth.highPass` / `bandPass` (filter design, SciPy
compatible), `SosFilter` (`filter` = `sosfilt`, `filterZeroPhase` = `sosfiltfilt`), `Windows`
(Hann, Kaiser, Kaiser FIR).

### 8. Show a spectrum or analyse frequencies

`RealFft` wraps [fftea](https://pub.dev/packages/fftea) with NumPy's `rfft` conventions:

```dart
final RealFft fft = RealFft(2048);
final Float64x2List spectrum = fft.forward(frame); // frame: 2048 samples, ideally windowed
final Float64List magnitudes = RealFft.magnitudes(spectrum); // 1025 bins, 0 … sampleRate / 2
```

`forwardPair` / `inversePair` transform two real frames with one complex FFT (twice as fast).

### 9. Work with bytes (web, downloads, uploads, other codecs)

```dart
final PcmAudio audio = WavCodec.decode(bytes); // 8/16/24/32-bit PCM or 32/64-bit float WAV
final Uint8List out = WavCodec.encode24(VocalEnhancer().enhance(audio).audio);
```

Any decoder that gives float samples in −1…1 works too: build
`PcmAudio(samples: [left, right], sampleRate: 48000)` from `Float64List`s.

## The chain

`VocalEnhancer.enhance` runs these steps in order; a step whose amount is 0 is skipped.

| Step | Tool | What it does |
|---|---|---|
| 1 | `BiquadFilters.highPass` | 2nd-order Butterworth high-pass: removes rumble and handling noise |
| 2 | `NoiseReducer` | spectral gate with a learned noise profile (STFT, Hann, 75 % overlap) |
| 3 | `BiquadFilters.equalize` | peaking "mud" cut, "presence" boost, "air" high shelf |
| 4 | `DynamicsProcessor.deEss` | lowers the 5–9 kHz band while it dominates ("s", "sh") |
| 5 | `DynamicsProcessor.compress` | soft-knee compressor, threshold relative to the loudness |
| 6 | `LoudnessMeter` + gain | normalises to a target integrated loudness (ITU-R BS.1770, LUFS) |
| 7 | `DynamicsProcessor.limit` | look-ahead true-peak limiter (4× oversampled peaks) |
| 8 | `SilenceTrimmer` | optional: cuts the silence before and after the voice |

## Settings

`EnhanceSettings` — levels in dB, frequencies in Hz, times in seconds.

| Setting | Default | Meaning |
|---|---|---|
| `highPassHz` | 80 | corner of the rumble filter (0 = off); 100–120 for speech |
| `noiseReductionDb` | 16 | how much steady noise is lowered (0 = off) |
| `noiseSensitivity` | 1.5 | higher = more counts as noise (cleaner, but may thin the voice) |
| `noiseProfileSeconds` | 0 | leading room tone used as the noise profile (0 = search automatically) |
| `mudCutDb` / `mudHz` | −2 / 250 | removes boominess |
| `presenceDb` / `presenceHz` | 1.5 / 3500 | makes words clearer |
| `airDb` / `airHz` | 2 / 10000 | high shelf for air and sparkle |
| `deEssDb` | 6 | most the "s" band may be lowered (0 = off) |
| `compressionRatio` | 3 | 1 = off |
| `compressionThresholdDb` | −2 | relative to the loudness of the recording |
| `compressionAttackSeconds` / `ReleaseSeconds` | 0.01 / 0.15 | compressor speed |
| `targetLufs` | −14 | final loudness; −16 for podcasts, −23 for broadcast (EBU R128) |
| `truePeakDb` | −1 | limiter ceiling in dBTP |
| `limiterReleaseSeconds` | 0.08 | limiter recovery |
| `trimSilence` / `trimPaddingSeconds` | false / 0.3 | cut silence, keeping this much around the voice |

## Presets

- `EnhancePreset.natural` — gentle cleanup, keeps the room and the dynamics (the defaults);
- `EnhancePreset.studio` — stronger noise reduction, more presence, tighter compression;
- `EnhancePreset.loudnessOnly` — only loudness and limiting.

Change any value on top of a preset with `copyWith`.

## Limits

- Offline only: give it the whole recording.
- Removes **steady** noise (hum, hiss, fans). Clicks, music, traffic bursts and other voices stay.
- Holds the whole recording in memory as 64-bit floats: about 23 MB per minute of mono 48 kHz,
  plus a few working copies.
- Sample rates of 16 kHz and up give the expected results (the de-esser works on 5–9 kHz).

## Accuracy

The port is checked number for number against the reference Python implementation (NumPy /
SciPy): every tool and the whole chain, mono 48 kHz and stereo 44.1 kHz, match to about 1e-6 of
full scale (the precision of the stored float32 references), and a real recording comes out
bit-identical in 24-bit. `tool/make_fixtures.py` regenerates the references.

## Performance

On a 48 s mono voice recording (Apple M-series, `dart compile exe`) the whole chain takes about
as long as the NumPy/SciPy version (~0.8–1.3 s). The hot loops use `Float64x2` SIMD, the
true-peak search skips blocks that provably cannot reach the level in question, and the STFT packs
two real frames into each complex FFT. `tool/benchmark.dart` measures it on your machine.

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
