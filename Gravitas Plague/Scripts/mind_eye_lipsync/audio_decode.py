from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import subprocess


@dataclass(frozen=True, slots=True)
class AudioProbe:
    codec_name: str
    channels: int
    sample_rate: int
    format_duration_seconds: float | None


def run_checked(
    arguments: list[str],
    *,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    completed = subprocess.run(arguments, check=False, capture_output=capture_output)
    if completed.returncode != 0:
        message = completed.stderr.decode("utf-8", errors="replace")
        raise RuntimeError(f"Command failed: {arguments[0]}: {message.strip()}")
    return completed


def probe_audio(ffprobe: Path, source: Path) -> AudioProbe:
    result = run_checked([
        str(ffprobe), "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=codec_name,channels,sample_rate:format=duration",
        "-of", "json", str(source),
    ])
    payload = json.loads(result.stdout.decode("utf-8"))
    streams = payload.get("streams", [])
    if len(streams) != 1:
        raise RuntimeError("Expected exactly one audio stream")
    stream = streams[0]
    duration = payload.get("format", {}).get("duration")
    return AudioProbe(
        codec_name=str(stream["codec_name"]),
        channels=int(stream["channels"]),
        sample_rate=int(stream["sample_rate"]),
        format_duration_seconds=float(duration) if duration else None,
    )


def decode_wav(
    ffmpeg: Path,
    source: Path,
    destination: Path,
    *,
    sample_rate: int,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    run_checked([
        str(ffmpeg), "-v", "error", "-nostdin", "-y", "-i", str(source),
        "-map_metadata", "-1", "-vn", "-ac", "1", "-ar", str(sample_rate),
        "-sample_fmt", "s16", "-c:a", "pcm_s16le", str(destination),
    ])


def run_apple_timeline_probe(probe: Path, source: Path) -> bytes:
    return run_checked([str(probe), str(source)]).stdout
