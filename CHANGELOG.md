## Unreleased

- Releases are published to pub.dev by GitHub Actions from a pushed `vX.Y.Z` tag (`tool/release.sh`).
- The same workflow then creates the GitHub release, with the CHANGELOG section of the version as its notes.

## 0.3.1

- README: the install line names the current version, and the default loudness is −15 LUFS.

## 0.3.0

- **Every step can be fine tuned**: the values each step kept to itself are now `EnhanceSettings`
  fields (and optional parameters of the step), with the old values as defaults, so the sound does
  not change unless you ask: `alignMaxLagSeconds`, `toneNoBoostBelowHz`, `noiseTransitionDb`,
  `deEssLowHz`, `deEssHighHz`, `deEssAboveVoiceDb`, `deEssAttackSeconds`, `deEssReleaseSeconds`,
  `compressionKneeDb`, `expanderOpenSeconds`, `expanderCloseSeconds`, `monoWidthLowHz`,
  `monoWidthHighHz`, `limiterLookaheadSeconds`, `limiterMakeupMaxDb`, `trimAboveNoiseDb`,
  `trimBelowLoudDb`, `trimSilenceBelowLoudDb`, `trimFadeSeconds`.
- `SilenceTrimmer` no longer cuts sung parts of a take that is loud all along (music from the
  speaker under the voice): silence is now always at least 25 dB under the loudest blocks
  (`trimSilenceBelowLoudDb`). Before, the quietest tenth of such a take was taken for the noise
  floor, and up to half of it was cut.

## 0.2.0

- New steps: `StereoAligner` (removes the hollow sound of two spaced phone microphones),
  `ToneBalancer` with `ToneCurve` (automatic tone balance, linear-phase FIR) and
  `DynamicsProcessor.expand` (keeps the pauses and the room quiet), `MonoWidener` (a mono take
  becomes mono-compatible stereo: early reflections on the sides, which cancel in a mono sum).
- **The natural preset changes**: tone balance instead of the fixed EQ, a compressor on the peaks
  only, the expander, mono widening, −15 LUFS. The 0.1 sound is kept as `EnhancePreset.classic`.
- `EnhanceSettings.maxGainDb` (40 dB by default, was a fixed 30 dB) so very quiet takes reach
  the target loudness.
- New building blocks: `FirFilter`, `Windows.firwin2`, `Windows.hamming`, `Spectral.welch`.

## 0.1.0

- First release: the whole vocal chain (high-pass, spectral noise reduction, EQ, de-esser,
  compressor, BS.1770 loudness, true-peak limiter, silence trim), presets, recording analysis,
  WAV codec and a real-FFT wrapper over fftea. Verified against the NumPy/SciPy reference.
- Every operation can run synchronously, as a `Future` in a background isolate, or as an
  `AudioTask` with a `Stream<AudioProgress>` and `cancel()`; `AudioTask.start` runs any tool.
