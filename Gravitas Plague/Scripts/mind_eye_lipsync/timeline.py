from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import struct

from .constants import FRAMES_PER_SECOND, SAMPLES_PER_NOMINAL_FRAME, TIMELINE_SAMPLE_RATE


@dataclass(frozen=True, slots=True)
class AudioTimeline:
    sample_rate: int
    sample_count: int
    frames_per_second: int
    samples_per_nominal_frame: int
    frame_count: int

    @property
    def duration_seconds(self) -> float:
        return self.sample_count / self.sample_rate

    def frame_range(self, frame_index: int) -> tuple[int, int]:
        if not 0 <= frame_index < self.frame_count:
            raise IndexError(frame_index)
        start = frame_index * self.samples_per_nominal_frame
        return start, min(start + self.samples_per_nominal_frame, self.sample_count)


@dataclass(frozen=True, slots=True)
class DecoderParity:
    ffmpeg_sample_count: int
    apple_sample_count: int
    signed_difference: int
    warning: str | None


def timeline_for_sample_count(sample_count: int) -> AudioTimeline:
    if sample_count <= 0:
        raise ValueError("Timeline must contain at least one sample")
    frame_count = (sample_count + SAMPLES_PER_NOMINAL_FRAME - 1) // SAMPLES_PER_NOMINAL_FRAME
    return AudioTimeline(
        sample_rate=TIMELINE_SAMPLE_RATE,
        sample_count=sample_count,
        frames_per_second=FRAMES_PER_SECOND,
        samples_per_nominal_frame=SAMPLES_PER_NOMINAL_FRAME,
        frame_count=frame_count,
    )


def parse_pcm_wav(path: Path, *, expected_sample_rate: int = TIMELINE_SAMPLE_RATE) -> AudioTimeline:
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("Expected standard RIFF/WAVE input; RF64 is unsupported")
    offset = 12
    fmt: tuple[int, int, int, int, int] | None = None
    data_size: int | None = None
    data_chunks = 0
    while offset + 8 <= len(data):
        chunk_id = data[offset:offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        payload_start = offset + 8
        payload_end = payload_start + chunk_size
        if payload_end > len(data):
            raise ValueError("Truncated WAV chunk")
        if chunk_id == b"fmt ":
            if fmt is not None or chunk_size < 16:
                raise ValueError("Invalid or duplicate WAV fmt chunk")
            audio_format, channels, sample_rate, _, block_align, bits = struct.unpack_from(
                "<HHIIHH", data, payload_start
            )
            fmt = (audio_format, channels, sample_rate, block_align, bits)
        elif chunk_id == b"data":
            data_chunks += 1
            data_size = chunk_size
        offset = payload_end + (chunk_size & 1)
    if fmt is None or data_size is None or data_chunks != 1:
        raise ValueError("WAV must contain exactly one fmt and one data chunk")
    audio_format, channels, sample_rate, block_align, bits = fmt
    if (audio_format, channels, sample_rate, block_align, bits) != (
        1, 1, expected_sample_rate, 2, 16
    ):
        raise ValueError(
            "WAV must be PCM16 mono at "
            f"{expected_sample_rate} Hz; got format={audio_format} channels={channels} "
            f"rate={sample_rate} align={block_align} bits={bits}"
        )
    if data_size == 0 or data_size % block_align:
        raise ValueError("WAV data is empty or ends with a partial sample")
    if expected_sample_rate != TIMELINE_SAMPLE_RATE:
        raise ValueError("Only the canonical 48 kHz timeline produces frame ranges")
    return timeline_for_sample_count(data_size // block_align)


def compare_decoder_counts(ffmpeg_sample_count: int, apple_sample_count: int) -> DecoderParity:
    difference = apple_sample_count - ffmpeg_sample_count
    absolute = abs(difference)
    if absolute > 400:
        raise ValueError(
            "Apple/ffmpeg decoded sample counts differ by more than half a visual frame: "
            f"ffmpeg={ffmpeg_sample_count} apple={apple_sample_count} difference={difference}"
        )
    warning = None
    if absolute > 48:
        warning = f"decoder sample count differs by {difference} samples"
    return DecoderParity(ffmpeg_sample_count, apple_sample_count, difference, warning)


def parse_apple_probe_output(data: bytes) -> int:
    payload = json.loads(data.decode("utf-8"))
    if payload.get("schemaVersion") != 1 or payload.get("decodedSampleRate") != 48_000:
        raise ValueError("Apple timeline probe emitted an unsupported contract")
    count = payload.get("decodedSampleCount")
    if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
        raise ValueError("Apple timeline probe emitted an invalid sample count")
    return count
