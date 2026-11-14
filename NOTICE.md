# Third-party notices

revoockv_audio_enhance groups established audio tools into one chain. Its Dart code is an
independent re-implementation that follows the algorithms, formulas and published constants of
the projects below, to give the same results. Their copyright notices are kept here.

## SciPy — BSD-3-Clause

<https://github.com/scipy/scipy> — Copyright (c) 2001-2002 Enthought, Inc. 2003, SciPy Developers.
Followed: `scipy.signal` (butter, buttap, lp2hp_zpk, lp2bp_zpk, bilinear_zpk, zpk2sos, sosfilt,
sosfiltfilt, sosfilt_zi, lfilter_zi, resample_poly, firwin, firwin2, fftconvolve, welch,
windows.kaiser, get_window),
`scipy.ndimage.uniform_filter`, `scipy.io.wavfile`.

## NumPy — BSD-3-Clause

<https://github.com/numpy/numpy> — Copyright (c) 2005-2025, NumPy Developers.
Followed: `numpy.fft.rfft` / `irfft` conventions, `percentile` (linear), `interp`, `linspace`,
stable `argsort`.

## libebur128 — MIT

<https://github.com/jiixyj/libebur128> — Copyright (c) 2011 Jan Kokemüller.
Used: the sample-rate-independent K-weighting filter parameters (shelf and high-pass
frequencies, gains and Q values).

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions: The above copyright
> notice and this permission notice shall be included in all copies or substantial portions of
> the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

## fftea — Apache-2.0

<https://github.com/liamappelbe/fftea> — a dependency (not copied); `RealFft` wraps its `FFT`.

## Standards and references

- ITU-R BS.1770, "Algorithms to measure audio programme loudness and true-peak audio level":
  <https://www.itu.int/rec/R-REC-BS.1770>
- Robert Bristow-Johnson, "Audio EQ Cookbook": <https://www.w3.org/TR/audio-eq-cookbook/>
- Spectral gating, as popularised by noisereduce (MIT): <https://github.com/timsainb/noisereduce>
