"""Writes the reference outputs of the Python engine that the Dart tests compare against.

Run from the package root (needs the revoockv-vocal-enhance Python project for numpy/scipy):

    uv run --project ~/.agents/skills/revoockv-vocal-enhance python tool/make_fixtures.py

Every signal is stored as little-endian float32, channels one after another. The inputs are
float32 too, so Python and Dart process exactly the same numbers.
"""

import json
import logging
import math
from dataclasses import asdict, replace
from pathlib import Path

import numpy as np

from vocal_enhance.features.enhance.data.services.biquad_filter_service import (
    BiquadFilterService,
)
from vocal_enhance.features.enhance.data.services.dynamics_service import DynamicsService
from vocal_enhance.features.enhance.data.services.loudness_service import LoudnessService
from vocal_enhance.features.enhance.data.services.noise_reduction_service import (
    NoiseReductionService,
)
from vocal_enhance.features.enhance.data.services.silence_trim_service import SilenceTrimService
from vocal_enhance.features.enhance.data.data_sources.wav_file_data_source import PcmAudio
from vocal_enhance.features.enhance.data.repositories.enhance_repository_impl import (
    EnhanceRepositoryImpl,
)
from vocal_enhance.features.enhance.domain.entities.enhance_preset import EnhancePreset
from vocal_enhance.features.enhance.domain.entities.enhance_settings import EnhanceSettings

OUT = Path(__file__).resolve().parent.parent / "test" / "fixtures"


def voice(rate: int, seconds: float, channels: int, seed: int) -> np.ndarray:
    """Room noise, a lead-in of near silence, sung vowels, "s" sounds and one hot peak."""
    rng = np.random.default_rng(seed)
    n = round(rate * seconds)
    t = np.arange(n) / rate
    out = np.zeros((channels, n))
    for c in range(channels):
        noise = rng.normal(0, 10 ** (-52 / 20), n)
        vowel = np.zeros(n)
        for h in range(1, 12):
            vowel += np.sin(2 * math.pi * 196 * h * t + h * (c + 1)) / h**1.3
        envelope = np.clip(np.sin(2 * math.pi * 1.3 * (t - 0.3)), 0, None) * (t > 0.3)
        sibilance = rng.normal(0, 1, n)
        sibilance = np.convolve(sibilance, np.ones(3) / 3, mode="same") - np.convolve(
            sibilance, np.ones(15) / 15, mode="same"
        )
        s_env = ((t > 0.55) & (t < 0.62)) | ((t > 0.85) & (t < 0.9))
        hot = np.exp(-(((t - 0.75) / 0.004) ** 2)) * 0.9
        out[c] = noise + 0.25 * envelope * vowel + 0.15 * s_env * sibilance + hot * np.sin(
            2 * math.pi * 3000 * t
        )
    return out.astype(np.float32).astype(np.float64)


def save(folder: Path, name: str, samples: np.ndarray) -> None:
    np.ascontiguousarray(np.atleast_2d(samples), dtype="<f4").tofile(folder / f"{name}.f32")


def number(value: float) -> float | str:
    return value if math.isfinite(value) else ("inf" if value > 0 else "-inf")


def main() -> None:
    filters = BiquadFilterService()
    loudness = LoudnessService(filters)
    dynamics = DynamicsService(filters=filters, loudness=loudness)
    noise = NoiseReductionService()
    trim = SilenceTrimService()

    repository = EnhanceRepositoryImpl(
        wav_files=None,  # type: ignore[arg-type]
        filters=filters,
        noise_reduction=noise,
        dynamics=dynamics,
        loudness=loudness,
        silence_trim=trim,
        logger=logging.getLogger("fixtures"),
    )

    def run_chain(x: np.ndarray, rate: int, settings: EnhanceSettings) -> tuple[np.ndarray, list[int]]:
        """The chain of ``EnhanceRepositoryImpl._enhance`` without the file reading and writing."""
        samples = x
        for step in repository._chain:
            samples = step.run(samples, rate, settings)
        start, end = 0, samples.shape[1]
        if settings.trim_silence > 0:
            start, end = trim.kept_range(samples, rate, padding_s=settings.trim_padding_s)
            samples = trim.cut(samples, rate, start=start, end=end)
        return samples, [start, end]

    cases = {
        "mono48": (48000, 1.2, 1, 1),
        "stereo44": (44100, 1.0, 2, 2),
    }
    index: dict[str, object] = {}
    for name, (rate, seconds, channels, seed) in cases.items():
        folder = OUT / name
        folder.mkdir(parents=True, exist_ok=True)
        x = voice(rate, seconds, channels, seed)
        save(folder, "input", x)
        save(folder, "high_pass", filters.high_pass(x, rate, corner_hz=80))
        save(folder, "band", filters.band(x, rate, low_hz=5000, high_hz=9000))
        save(
            folder,
            "equalize",
            filters.equalize(x, rate, bells=[(250, -2), (3500, 1.5)], high_shelf=(10000, 2)),
        )
        save(folder, "oversampled_peaks", loudness.oversampled_peaks(x, floor=0.0))
        save(folder, "de_ess", dynamics.de_ess(x, rate, max_reduction_db=6))
        save(
            folder,
            "compress",
            dynamics.compress(
                x, rate, ratio=3, threshold_db=-2, attack_s=0.01, release_s=0.15
            ),
        )
        save(folder, "limit", dynamics.limit(x * 4, rate, ceiling_db=-1, release_s=0.08))
        save(
            folder,
            "noise_auto",
            noise.reduce(x, rate, reduction_db=16, sensitivity=1.5, profile_seconds=0),
        )
        save(
            folder,
            "noise_profile",
            noise.reduce(x, rate, reduction_db=22, sensitivity=1.5, profile_seconds=0.25),
        )
        start, end = trim.kept_range(x, rate, padding_s=0.05)
        save(folder, "trim", trim.cut(x, rate, start=start, end=end))
        chains = {}
        for preset in EnhancePreset:
            settings = preset.settings()
            if preset is EnhancePreset.STUDIO:
                settings = replace(settings, trim_silence=1.0, trim_padding_s=0.05)
            result, kept = run_chain(x, rate, settings)
            save(folder, f"chain_{preset.value}", result)
            chains[preset.value] = {"settings": asdict(settings), "kept": kept}
        analysis = loudness.measure(PcmAudio(samples=x, sample_rate=rate))
        index[name] = {
            "sample_rate": rate,
            "channels": channels,
            "frames": x.shape[1],
            "k_weighting": filters.k_weighting(rate).tolist(),
            "integrated_lufs": number(loudness.integrated_lufs(x, rate)),
            "true_peak": loudness.true_peak(x),
            "measure": {k: number(v) for k, v in asdict(analysis).items()},
            "kept_range": [start, end],
            "chains": chains,
        }
    (OUT / "fixtures.json").write_text(json.dumps(index, indent=2) + "\n")


if __name__ == "__main__":
    main()
