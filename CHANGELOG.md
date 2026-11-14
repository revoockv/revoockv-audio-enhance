## 0.1.0

- First release: the whole vocal chain (high-pass, spectral noise reduction, EQ, de-esser,
  compressor, BS.1770 loudness, true-peak limiter, silence trim), presets, recording analysis,
  WAV codec and a real-FFT wrapper over fftea. Verified against the NumPy/SciPy reference.
- Every operation can run synchronously, as a `Future` in a background isolate, or as an
  `AudioTask` with a `Stream<AudioProgress>` and `cancel()`; `AudioTask.start` runs any tool.
