## 0.2.0

- New steps: `StereoAligner` (removes the hollow sound of two spaced phone microphones),
  `ToneBalancer` with `ToneCurve` (automatic tone balance, linear-phase FIR) and
  `DynamicsProcessor.expand` (keeps the pauses and the room quiet).
- **The natural preset changes**: tone balance instead of the fixed EQ, a compressor on the peaks
  only, the expander, −15 LUFS. The 0.1 sound is kept as `EnhancePreset.classic`.
- `EnhanceSettings.maxGainDb` (40 dB by default, was a fixed 30 dB) so very quiet takes reach
  the target loudness.
- New building blocks: `FirFilter`, `Windows.firwin2`, `Windows.hamming`, `Spectral.welch`.

## 0.1.0

- First release: the whole vocal chain (high-pass, spectral noise reduction, EQ, de-esser,
  compressor, BS.1770 loudness, true-peak limiter, silence trim), presets, recording analysis,
  WAV codec and a real-FFT wrapper over fftea. Verified against the NumPy/SciPy reference.
- Every operation can run synchronously, as a `Future` in a background isolate, or as an
  `AudioTask` with a `Stream<AudioProgress>` and `cancel()`; `AudioTask.start` runs any tool.
