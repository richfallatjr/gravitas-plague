from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path
import wave
from typing import Any, Callable, Protocol, Sequence

from .constants import ANALYSIS_SAMPLE_RATE, TIMELINE_SAMPLE_RATE
from .hashing import sha256_bytes


@dataclass(frozen=True, slots=True)
class VADWindow:
    start_sample_16k: int
    end_sample_16k: int
    speech_probability: float


@dataclass(frozen=True, slots=True)
class SpeechSpan:
    start_sample_48k: int
    end_sample_48k: int


@dataclass(frozen=True, slots=True)
class VADResult:
    windows: tuple[VADWindow, ...]
    speech_spans: tuple[SpeechSpan, ...]
    model_sha256: str
    package_version: str
    configuration_sha256: str


class ProbabilityModel(Protocol):
    def reset_states(self) -> None: ...
    def __call__(self, samples: Sequence[float], sample_rate: int) -> float: ...


def read_pcm16_mono_wav(path: Path, *, expected_rate: int = ANALYSIS_SAMPLE_RATE) -> tuple[float, ...]:
    with wave.open(str(path), "rb") as source:
        if (
            source.getnchannels() != 1
            or source.getframerate() != expected_rate
            or source.getsampwidth() != 2
            or source.getcomptype() != "NONE"
        ):
            raise ValueError(f"Expected PCM16 mono {expected_rate} Hz analysis WAV")
        frames = source.readframes(source.getnframes())
    if not frames or len(frames) % 2:
        raise ValueError("Analysis WAV is empty or contains a partial sample")
    import array
    values = array.array("h")
    values.frombytes(frames)
    if values.itemsize != 2:
        raise RuntimeError("Host int16 representation is unsupported")
    if __import__("sys").byteorder != "little":
        values.byteswap()
    result = tuple(float(value) / 32768.0 for value in values)
    if not all(math.isfinite(value) and -1 <= value <= 1 for value in result):
        raise ValueError("Analysis WAV produced nonfinite or out-of-range samples")
    return result


def probability_windows(
    samples: Sequence[float],
    model: ProbabilityModel,
    *,
    window_samples: int = 512,
) -> tuple[VADWindow, ...]:
    if not samples or window_samples <= 0:
        raise ValueError("VAD requires nonempty samples and a positive window")
    model.reset_states()
    windows: list[VADWindow] = []
    for start in range(0, len(samples), window_samples):
        end = min(start + window_samples, len(samples))
        padded = list(samples[start:end])
        padded.extend([0.0] * (window_samples - len(padded)))
        probability = float(model(padded, ANALYSIS_SAMPLE_RATE))
        if not math.isfinite(probability) or not 0 <= probability <= 1:
            raise ValueError(f"Silero returned invalid probability {probability}")
        windows.append(VADWindow(start, end, probability))
    return tuple(windows)


def map_speech_spans(
    spans_16k: Sequence[dict[str, Any] | tuple[int, int]],
    *,
    timeline_sample_count: int,
) -> tuple[SpeechSpan, ...]:
    result: list[SpeechSpan] = []
    previous_end = 0
    for item in spans_16k:
        if isinstance(item, dict):
            start16, end16 = int(item["start"]), int(item["end"])
        else:
            start16, end16 = map(int, item)
        start = start16 * (TIMELINE_SAMPLE_RATE // ANALYSIS_SAMPLE_RATE)
        end = min(end16 * (TIMELINE_SAMPLE_RATE // ANALYSIS_SAMPLE_RATE), timeline_sample_count)
        if start < previous_end or start < 0 or end <= start or end > timeline_sample_count:
            raise ValueError("Silero speech spans are invalid or overlapping")
        result.append(SpeechSpan(start, end))
        previous_end = end
    return tuple(result)


def vad_configuration_sha256(config: dict[str, Any]) -> str:
    encoded = json.dumps(config, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    return sha256_bytes(encoded)


class _SileroAdapter:
    def __init__(self, model: Any, torch_module: Any) -> None:
        self.model = model
        self.torch = torch_module

    def reset_states(self) -> None:
        self.model.reset_states()

    def __call__(self, samples: Sequence[float], sample_rate: int) -> float:
        tensor = self.torch.tensor(samples, dtype=self.torch.float32)
        return float(self.model(tensor, sample_rate).item())


def analyze_vad(
    analysis_wav: Path,
    *,
    timeline_sample_count: int,
    config: dict[str, Any],
    model_sha256: str,
    package_version: str,
) -> VADResult:
    try:
        import torch
        import silero_vad
        from silero_vad import get_speech_timestamps, load_silero_vad
    except ImportError as error:
        raise RuntimeError("Pinned Silero VAD authoring environment is unavailable") from error
    torch.set_num_threads(1)
    samples = read_pcm16_mono_wav(analysis_wav)
    model = load_silero_vad(onnx=True, opset_version=16)
    adapter = _SileroAdapter(model, torch)
    windows = probability_windows(samples, adapter, window_samples=int(config["windowSamples"]))
    model.reset_states()
    tensor = torch.tensor(samples, dtype=torch.float32)
    spans = get_speech_timestamps(
        tensor,
        model,
        sampling_rate=ANALYSIS_SAMPLE_RATE,
        threshold=float(config["threshold"]),
        neg_threshold=float(config["negativeThreshold"]),
        min_speech_duration_ms=int(config["minSpeechDurationMs"]),
        min_silence_duration_ms=int(config["minSilenceDurationMs"]),
        speech_pad_ms=int(config["speechPadMs"]),
        max_speech_duration_s=float(config["maximumSpeechDurationSeconds"]),
        return_seconds=False,
    )
    return VADResult(
        windows=windows,
        speech_spans=map_speech_spans(spans, timeline_sample_count=timeline_sample_count),
        model_sha256=model_sha256,
        package_version=package_version,
        configuration_sha256=vad_configuration_sha256(config),
    )


def overlap_samples(start: int, end: int, spans: Sequence[SpeechSpan]) -> int:
    return sum(max(0, min(end, span.end_sample_48k) - max(start, span.start_sample_48k)) for span in spans)
