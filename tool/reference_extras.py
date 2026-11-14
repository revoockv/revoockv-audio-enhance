"""Reference implementation (NumPy/SciPy) of the steps added in 0.2.0, for the Dart tests.

The 0.1.0 steps come from the revoockv-vocal-enhance engine; these three were designed here:
stereo alignment, automatic tone balance (auto-EQ) and a downward expander for the pauses.
"""

import numpy as np
from scipy import signal

TONE_CENTRES = np.array(
    [63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500,
     3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000],
    dtype=float,
)
"""Centres of the third-octave bands of the tone analysis, in Hz."""

BALANCED_CURVE = np.array(
    [-27.0, -20.2, -13.1, -9.3, -8.6, -7.6, -4.2, -0.5, 0.0, -1.5, -4.1, -6.1, -8.7, -10.6,
     -12.0, -12.7, -13.6, -14.9, -16.5, -18.0, -19.2, -20.2, -20.4, -20.0, -19.1],
)
"""Target long-term spectrum (dB per band): a smoothed reference recording of voice and guitar."""

_MAX_LAG_S = 0.001
_ALIGN_WINDOW_S = 20
_BLOCK_S = 0.05
_VOICED_PERCENTILE = 40
_WELCH_SEGMENT = 8192
_FIR_TAPS = 4097
_NO_BOOST_BELOW_HZ = 150
_LEVEL_LOW_HZ = 200
_LEVEL_HIGH_HZ = 4000
_MAX_BAND = 0.45
_EXPANDER_FRAME_S = 0.005
_EXPANDER_OPEN_S = 0.005
_EXPANDER_CLOSE_S = 0.15


def align_stereo(x: np.ndarray, rate: int) -> np.ndarray:
    """Shift one channel by the delay between the microphones (up to 1 ms) and match levels."""
    if x.shape[0] != 2:
        return x
    left, right = x
    n = min(left.size, rate * _ALIGN_WINDOW_S)
    m = int(_MAX_LAG_S * rate)
    best, lag = -np.inf, 0
    for k in range(-m, m + 1):  # c(k) = sum left[i + k] * right[i]
        if k >= 0:
            c = float(np.dot(left[k:n], right[: n - k]))
        else:
            c = float(np.dot(left[: n + k], right[-k:n]))
        if c > best:
            best, lag = c, k
    if lag > 0:
        left = np.concatenate([left[lag:], np.zeros(lag)])
    elif lag < 0:
        right = np.concatenate([right[-lag:], np.zeros(-lag)])
    gl = np.sqrt(np.mean(left**2))
    gr = np.sqrt(np.mean(right**2))
    if gl == 0 or gr == 0:
        return np.stack([left, right])
    g = np.sqrt(gl * gr)
    return np.stack([left * (g / gl), right * (g / gr)])


def tone_bands(x: np.ndarray, rate: int, centres: np.ndarray) -> np.ndarray:
    """Long-term level (dB) of every third-octave band, over the louder 60 % of 50 ms blocks."""
    mono = x.mean(axis=0)
    b = int(_BLOCK_S * rate)
    nb = mono.size // b
    blocks = mono[: nb * b].reshape(nb, b)
    lev = (blocks**2).mean(axis=1)
    voiced = blocks[lev >= np.percentile(lev, _VOICED_PERCENTILE)].reshape(-1)
    fr, p = signal.welch(voiced, rate, nperseg=min(_WELCH_SEGMENT, voiced.size))
    return np.array(
        [10 * np.log10(p[(fr >= c / 2 ** (1 / 6)) & (fr < c * 2 ** (1 / 6))].sum() + 1e-30)
         for c in centres]
    )


def tone_correction(x: np.ndarray, rate: int, max_boost: float, max_cut: float) -> tuple:
    """The centres in use and the smoothed, limited correction (dB) towards the curve."""
    use = TONE_CENTRES < _MAX_BAND * rate
    centres = TONE_CENTRES[use]
    corr = BALANCED_CURVE[use] - tone_bands(x, rate, centres)
    corr -= np.median(corr[(centres >= _LEVEL_LOW_HZ) & (centres <= _LEVEL_HIGH_HZ)])
    corr = np.convolve(np.pad(corr, 1, mode="edge"), [0.25, 0.5, 0.25], mode="valid")
    corr = np.clip(corr, -max_cut, max_boost)
    corr = np.where(centres < _NO_BOOST_BELOW_HZ, np.minimum(corr, 0), corr)
    return centres, corr


def auto_eq(x: np.ndarray, rate: int, max_boost: float = 12, max_cut: float = 12) -> np.ndarray:
    """Pull the long-term spectrum towards BALANCED_CURVE with a linear-phase FIR."""
    centres, corr = tone_correction(x, rate, max_boost, max_cut)
    freqs = np.concatenate([[0], centres, [rate / 2]])
    gains = np.concatenate([[corr[0]], corr, [corr[-1]]])
    h = signal.firwin2(_FIR_TAPS, freqs, 10 ** (gains / 20), fs=rate)
    return np.stack([signal.fftconvolve(ch, h, mode="same") for ch in x])


def expand(x: np.ndarray, rate: int, dynamics, loudness, below_db=20.0, ratio=2.0, floor_db=-12.0):
    """Lower what is more than below_db under the loudness (ratio:1, at most floor_db)."""
    if ratio <= 1:
        return x
    lufs = loudness.integrated_lufs(x, rate)
    if not np.isfinite(lufs):
        return x
    thr = lufs - below_db
    frame = max(1, round(_EXPANDER_FRAME_S * rate))
    lv = dynamics._frame_levels_db(x, frame)
    gain = np.where(lv < thr, np.maximum((lv - thr) * (ratio - 1), floor_db), 0.0)
    # Smoothing the reduction: it grows slowly (close) and shrinks fast (open).
    reduction = dynamics._smooth(
        -gain, frame_s=frame / rate, attack_s=_EXPANDER_OPEN_S, release_s=_EXPANDER_CLOSE_S
    )
    g = dynamics._per_sample(10 ** (-reduction / 20), frame, x.shape[1])
    return x * g
