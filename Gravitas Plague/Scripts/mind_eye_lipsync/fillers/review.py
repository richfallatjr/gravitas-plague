from __future__ import annotations

import html
import json
import math
import subprocess
import tempfile
from pathlib import Path
from typing import Iterable

import numpy as np

from ..config import PROJECT_ROOT, RESOURCES_ROOT
from .nonverbal_analyzer import read_pcm16
from .validator import load_and_validate_track


def _points(values: Iterable[float], x: float, y: float, width: float, height: float) -> str:
    values = list(values)
    if not values:
        return ""
    low, high = min(values), max(values)
    span = max(1e-9, high - low)
    count = max(1, len(values) - 1)
    return " ".join(
        f"{x + width * index / count:.2f},{y + height * (1 - (value - low) / span):.2f}"
        for index, value in enumerate(values)
    )


def _features(samples: np.ndarray) -> dict[str, object]:
    window, hop = 960, 480
    hann = np.hanning(window).astype(np.float64)
    rms: list[float] = []
    zcr: list[float] = []
    centroid: list[float] = []
    flux: list[float] = []
    prior = None
    for start in range(0, len(samples), hop):
        chunk = samples[start:min(len(samples), start + window)]
        if len(chunk) < window:
            chunk = np.pad(chunk, (0, window - len(chunk)))
        rms_value = math.sqrt(float(np.mean(chunk * chunk)))
        rms.append(20.0 * math.log10(max(1e-9, rms_value)))
        zcr.append(float(np.mean(np.signbit(chunk[1:]) != np.signbit(chunk[:-1]))))
        spectrum = np.abs(np.fft.rfft(chunk * hann))
        total = float(np.sum(spectrum))
        centroid.append(
            float(np.dot(np.arange(len(spectrum)), spectrum) / max(1e-12, total))
            / max(1, len(spectrum) - 1)
        )
        if prior is None:
            flux.append(0.0)
        else:
            positive = np.maximum(0.0, spectrum - prior)
            flux.append(
                float(np.sqrt(np.mean(positive * positive)))
                / max(1e-12, float(np.mean(spectrum)))
            )
        prior = spectrum
    floor, ceiling = np.percentile(rms, [20, 95])
    dynamic = max(18.0, float(ceiling - floor))
    threshold = max(-72.0, float(floor + max(6.0, 0.30 * dynamic)))
    return {
        "rms": rms,
        "zcr": zcr,
        "centroid": centroid,
        "flux": flux,
        "threshold": threshold,
        "activity": [value >= threshold for value in rms],
    }


def _expanded_poses(track: dict) -> list[str]:
    poses: list[str] = []
    for run in track["poseRuns"]:
        poses.extend([run["pose"]] * (run["endFrameExclusive"] - run["startFrame"]))
    return poses


def build_review(
    track_path: Path,
    output_directory: Path,
    toolchain_root: Path = PROJECT_ROOT / ".mind-eye-toolchains",
) -> dict[str, str]:
    track = load_and_validate_track(track_path)
    audio = RESOURCES_ROOT / track["audioResourcePath"]
    ffmpeg = toolchain_root / "bin" / "ffmpeg"
    if not ffmpeg.is_file():
        ffmpeg = toolchain_root / "mfa" / "bin" / "ffmpeg"
    if not ffmpeg.is_file():
        raise ValueError("Review renderer cannot find the pinned ffmpeg")
    with tempfile.TemporaryDirectory(prefix="mind-eye-filler-review.", dir=PROJECT_ROOT / ".build") as temp:
        wav = Path(temp) / "timeline.wav"
        subprocess.run(
            [str(ffmpeg), "-nostdin", "-v", "error", "-y", "-i", str(audio),
             "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", str(wav)],
            check=True,
        )
        samples, _ = read_pcm16(wav)
    trace = _features(samples)
    poses = _expanded_poses(track)
    waveform = samples[::max(1, len(samples) // 1_200)].tolist()
    pose_values = [
        {"rest": 0, "small": 1, "round": 2, "wide": 3, "teeth": 4}[pose]
        for pose in poses
    ]
    activity = [1.0 if value else 0.0 for value in trace["activity"]]
    rows = [
        ("waveform", waveform, "#a6e3a1"),
        ("activity gate", activity, "#f9e2af"),
        ("RMS / dB", trace["rms"], "#89b4fa"),
        ("zero-crossing rate", trace["zcr"], "#cba6f7"),
        ("spectral centroid", trace["centroid"], "#fab387"),
        ("spectral flux", trace["flux"], "#f38ba8"),
        ("final semantic pose", pose_values, "#94e2d5"),
    ]
    width, left, row_height = 1_280, 190, 92
    plot_width = width - left - 30
    svg_rows: list[str] = []
    for index, (label, values, color) in enumerate(rows):
        top = 50 + index * row_height
        svg_rows.append(
            f'<text x="18" y="{top + 32}" fill="#cdd6f4" font-size="16">{html.escape(label)}</text>'
            f'<rect x="{left}" y="{top}" width="{plot_width}" height="64" fill="#181825" stroke="#45475a"/>'
            f'<polyline points="{_points(values, left, top + 5, plot_width, 54)}" fill="none" '
            f'stroke="{color}" stroke-width="1.5"/>'
        )
    height = 80 + len(rows) * row_height
    title = html.escape(track["fillerID"])
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}"><rect width="100%" height="100%" fill="#11111b"/>'
        f'<text x="18" y="28" fill="#f5e0dc" font-size="20" font-weight="bold">{title}</text>'
        + "".join(svg_rows) + "</svg>\n"
    )
    output_directory.mkdir(parents=True, exist_ok=True)
    svg_path = output_directory / f'{track["fillerID"]}.review.svg'
    html_path = output_directory / f'{track["fillerID"]}.review.html'
    svg_path.write_text(svg, encoding="utf-8")
    html_path.write_text(
        "<!doctype html><meta charset=\"utf-8\"><title>" + title + "</title>"
        "<style>body{margin:0;background:#11111b;color:#cdd6f4;font:14px system-ui}"
        "header{padding:16px 20px}object{display:block;max-width:100%;height:auto}</style>"
        f"<header><strong>{title}</strong> · profile "
        f"{html.escape(str(track['authoring'].get('nonverbalProfile')))} · "
        f"activity threshold {float(trace['threshold']):.2f} dB</header>"
        f'<object data="{html.escape(svg_path.name)}" type="image/svg+xml" '
        f'width="{width}" height="{height}"></object>\n',
        encoding="utf-8",
    )
    return {"svg": str(svg_path), "html": str(html_path)}


def build_review_set(
    filler_set: Path,
    output_directory: Path,
    toolchain_root: Path = PROJECT_ROOT / ".mind-eye-toolchains",
) -> dict[str, object]:
    index = json.loads((filler_set / "index.json").read_text(encoding="utf-8"))
    reports = []
    for entry in index["entries"]:
        if entry["authoringMode"] != "nonverbal":
            continue
        reports.append(
            build_review(
                filler_set / "Tracks" / f'{entry["fillerID"]}.fillerframes.json',
                output_directory,
                toolchain_root,
            )
        )
    return {"status": "PASS", "reportCount": len(reports), "output": str(output_directory)}
