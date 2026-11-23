# revoockv_audio_enhance

Make a voice recording sound clean, clear and evenly loud — in pure Dart, with no native code, no
FFI and no Python. It runs the same on Android, iOS, macOS, Windows, Linux and the web.

This package does not invent new DSP. It **groups well-known audio-cleanup tools into one
chain** and ports each of them to Dart from the libraries where they come from (SciPy, NumPy,
libebur128, the RBJ cookbook — see [Based on](#based-on)). Use the whole chain in one call, or
any tool on its own.

- [Is it for me?](#is-it-for-me)
- [Quick start](#quick-start)
- [Three ways to call it](#three-ways-to-call-it)
- [Use cases](#use-cases)
- [The chain](#the-chain) · [Settings](#settings) · [Presets](#presets)
- [Limits](#limits) · [Accuracy](#accuracy) · [Performance](#performance)
- [Based on](#based-on) · [Licence](#licence)

## Is it for me?

**Yes, if you have a recorded file of a voice** — a sung take, a podcast, a voice memo, a
lesson, an interview — and want it to sound better before you play, share or export it:

- the hum, rumble and steady room noise (fan, fridge, hiss) are lowered;
- the tone is balanced automatically: a dull, boxy take gets its presence and air back;
- the hollow sound of the two spaced microphones of a phone is removed (stereo alignment);
- a mono take becomes stereo with a little room around the voice — and summed back to mono it
  is exactly the original, so a phone speaker loses nothing;
- the peaks are evened out while the pauses stay quiet, so the room does not come up with the
  voice; softer "s" sounds;
- the file ends up at a standard loudness (−15 LUFS by default; −14 for streaming services) and
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
  revoockv_audio_enhance: ^0.3.1
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

## Three ways to call it

Every operation of `VocalEnhancer` can be called with or without following its progress:

| Call | Returns | Runs | Progress |
|---|---|---|---|
| `enhance(audio)` / `analyze(audio)` | the value | right here, synchronously | none |
| `enhance(audio, onProgress: …)` | the value | right here, synchronously | callback |
| `enhanceAsync(audio)` / `analyzeAsync(audio)` | `Future` | background isolate | none |
| `enhanceTask(audio)` | `AudioTask` | background isolate | `Stream<AudioProgress>`, plus `cancel()` |

```dart
final VocalEnhancer enhancer = VocalEnhancer();

// 1. Synchronous — in a script, a server, or inside your own isolate.
final EnhanceResult a = enhancer.enhance(take);

// 2. In the background, only the result.
final EnhanceResult b = await enhancer.enhanceAsync(take);

// 3. In the background, with a progress stream; listening is optional.
final AudioTask<EnhanceResult> task = enhancer.enhanceTask(take);
task.progress.listen((AudioProgress p) => print('${(p.fraction * 100).round()} % ${p.label}'));
final EnhanceResult c = await task.result;
```

**Any single tool** runs the same way through `AudioTask.start`. The work receives a `report`
function; pass it the tool's progress if it has one:

```dart
final AudioTask<Samples> task = AudioTask<Samples>.start(
  (AudioProgressListener report) => const NoiseReducer().reduce(
    take.samples,
    take.sampleRate,
    reductionDb: 16,
    sensitivity: 1.5,
    profileSeconds: 0,
    onProgress: (double part) => report(AudioProgress.single('Reducing noise', part)),
  ),
);
final Samples cleaned = await task.result;
```

`task.cancel()` stops the work at once; `task.result` then fails with
`AudioTaskCancelledException`, and errors of the work arrive in `task.result` too. On the web
there are no isolates: the same API runs the work on the main thread, and `cancel()` only helps
before it has started.

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

`enhanceTask` runs the chain in a background isolate and gives a `Stream` of progress:

```dart
final AudioTask<EnhanceResult> task = VocalEnhancer().enhanceTask(take);
task.progress.listen((AudioProgress p) => setState(() => _progress = p.fraction)); // 0.0-1.0
// task.cancel() when the user leaves the page
final EnhanceResult result = await task.result;
```

In a widget a `StreamBuilder<AudioProgress>(stream: task.progress, …)` works as well.
`AudioProgress.label` names the step ("Reducing noise"); the longer steps also report how far
they are (`stepFraction`), so the bar keeps moving.

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
| 1 | `StereoAligner` | lines up the channels of two spaced microphones (±1 ms) and matches their levels |
| 2 | `ToneBalancer` | auto-EQ: pulls the long-term spectrum towards a `ToneCurve` (linear-phase FIR, ±12 dB) |
| 3 | `BiquadFilters.highPass` | 2nd-order Butterworth high-pass: removes rumble and handling noise |
| 4 | `NoiseReducer` | spectral gate with a learned noise profile (STFT, Hann, 75 % overlap) |
| 5 | `BiquadFilters.equalize` | optional fixed EQ: "mud" cut, "presence" boost, "air" shelf (off by default) |
| 6 | `DynamicsProcessor.deEss` | lowers the 5–9 kHz band while it dominates ("s", "sh") |
| 7 | `DynamicsProcessor.compress` | soft-knee compressor; by default it touches only the peaks |
| 8 | `DynamicsProcessor.expand` | downward expander: keeps the pauses and the room quiet |
| 9 | `MonoWidener` | mono → mid/side stereo: early reflections on the sides, mono-compatible |
| 10 | `LoudnessMeter` + gain | normalises to a target integrated loudness (ITU-R BS.1770, LUFS) |
| 11 | `DynamicsProcessor.limit` | look-ahead true-peak limiter (4× oversampled peaks) |
| 12 | `SilenceTrimmer` | optional: cuts the silence before and after the voice |

## Settings

`EnhanceSettings` — levels in dB, frequencies in Hz, times in seconds.

| Setting | Default | Meaning |
|---|---|---|
| `alignStereo` | true | line up the channels of a stereo take |
| `toneMaxBoostDb` / `toneMaxCutDb` | 12 / 12 | limits of the tone balance (both 0 = off) |
| `toneCurve` | `ToneCurve.balanced` | the spectrum the tone balance aims at |
| `highPassHz` | 80 | corner of the rumble filter (0 = off); 100–120 for speech |
| `noiseReductionDb` | 16 | how much steady noise is lowered (0 = off) |
| `noiseSensitivity` | 1.5 | higher = more counts as noise (cleaner, but may thin the voice) |
| `noiseProfileSeconds` | 0 | leading room tone used as the noise profile (0 = search automatically) |
| `mudCutDb` / `presenceDb` / `airDb` | 0 / 0 / 0 | fixed EQ at `mudHz` 250, `presenceHz` 3500, `airHz` 10000 |
| `deEssDb` | 6 | most the "s" band may be lowered (0 = off) |
| `compressionRatio` | 2 | 1 = off |
| `compressionThresholdDb` | +3 | relative to the loudness; above 0 only the peaks are compressed |
| `compressionAttackSeconds` / `ReleaseSeconds` | 0.01 / 0.15 | compressor speed |
| `expanderRatio` | 2 | 1 = off |
| `expanderBelowDb` / `expanderFloorDb` | 20 / −12 | works under loudness − 20 dB, lowers by at most 12 dB |
| `widenMono` / `monoWidthDb` | true / −12 | make a mono take stereo, the sides this far under the voice |
| `targetLufs` | −15 | final loudness; −14 for streaming, −16 for podcasts, −23 for broadcast |
| `maxGainDb` | 40 | most the loudness step raises a quiet take |
| `truePeakDb` | −1 | limiter ceiling in dBTP |
| `limiterReleaseSeconds` | 0.08 | limiter recovery |
| `trimSilence` / `trimPaddingSeconds` | false / 0.3 | cut silence, keeping this much around the voice |

### Fine tuning

Every value a step used to keep to itself is a setting too, with the old value as its default, so
you can tune the sound without waiting for a new version of the package:

| Setting | Default | What it does |
|---|---|---|
| `alignMaxLagSeconds` | 0.001 | largest delay between the channels the alignment looks for |
| `toneNoBoostBelowHz` | 150 | the tone balance only cuts below this |
| `noiseTransitionDb` | 6 | soft band around the noise threshold |
| `deEssLowHz` / `deEssHighHz` | 5000 / 9000 | band the de-esser lowers |
| `deEssAboveVoiceDb` | 10 | the de-esser acts when its band is less than this under the voice |
| `deEssAttackSeconds` / `deEssReleaseSeconds` | 0.001 / 0.04 | de-esser speed |
| `compressionKneeDb` | 6 | soft knee of the compressor |
| `expanderOpenSeconds` / `expanderCloseSeconds` | 0.005 / 0.15 | how fast the expander opens and closes |
| `monoWidthLowHz` / `monoWidthHighHz` | 300 / 7000 | band of the reflections of mono widening |
| `limiterLookaheadSeconds` | 0.005 | how far ahead the limiter looks |
| `limiterMakeupMaxDb` | 6 | most gain added back after the limiter |
| `trimAboveNoiseDb` | 10 | trim: a block is sound this far above the noise floor… |
| `trimBelowLoudDb` | 45 | …and no further than this under the loudest blocks |
| `trimSilenceBelowLoudDb` | 25 | trim: silence is always at least this far under the loudest blocks |
| `trimFadeSeconds` | 0.02 | fade where the take is cut |

```dart
final settings = EnhancePreset.natural.settings.copyWith(
  trimSilence: true,
  trimSilenceBelowLoudDb: 30,
  expanderCloseSeconds: 0.3,
);
```

Each step takes the same values as optional parameters when used on its own, for example
`SilenceTrimmer().keptRange(samples, rate, paddingSeconds: 0.3, silenceBelowLoudDb: 30)`.

## Presets

- `EnhancePreset.natural` — the defaults: balanced tone, peak-only compression, quiet pauses;
- `EnhancePreset.studio` — stronger noise reduction and de-essing, more compression, louder;
- `EnhancePreset.loudnessOnly` — only loudness and limiting;
- `EnhancePreset.classic` — the 0.1 chain: fixed EQ and a compressor that lifts the quiet parts.

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
bit-identical in 24-bit. The steps added in 0.2 (alignment, tone balance, expander) are checked
the same way against the NumPy/SciPy reference in `tool/reference_extras.py`.
`tool/make_fixtures.py` regenerates the references.

## Performance

On a 48 s mono voice recording (Apple M-series, `dart compile exe`) the whole chain takes about
as long as the NumPy/SciPy version (~0.8–1.3 s). The hot loops use `Float64x2` SIMD, the
true-peak search skips blocks that provably cannot reach the level in question, and the STFT packs
two real frames into each complex FFT. `tool/benchmark.dart` measures it on your machine.

## Based on

| Part | Ported from / follows | Licence |
|---|---|---|
| Butterworth design (`butter`, `buttap`, `lp2hp_zpk`, `lp2bp_zpk`, `bilinear_zpk`, `zpk2sos`), `sosfilt`, `sosfiltfilt`, `sosfilt_zi`, `lfilter_zi`, `resample_poly`, `firwin`, `windows.kaiser`, `get_window('hann')` | [SciPy](https://github.com/scipy/scipy) `scipy.signal` | BSD-3-Clause |
| `firwin2` (tone balance FIR), `fftconvolve`, `welch` (long-term spectrum) | [SciPy](https://github.com/scipy/scipy) `scipy.signal` | BSD-3-Clause |
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
