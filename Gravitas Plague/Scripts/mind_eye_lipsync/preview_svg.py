from __future__ import annotations

from html import escape
from typing import Any, Mapping

from .mfa_json import MFAAlignment
from .vad import VADResult


_POSE_COLORS = {
    "rest": "#64748b",
    "small": "#38bdf8",
    "wide": "#f59e0b",
    "round": "#a78bfa",
    "teeth": "#f8fafc",
}


def _x(sample: int, sample_count: int, left: int, width: int) -> float:
    return left + width * sample / max(1, sample_count)


def render_preview_svg(
    manifest: Mapping[str, Any],
    *,
    alignment: MFAAlignment | None = None,
    vad: VADResult | None = None,
) -> str:
    canvas_width, canvas_height = 1_400, 430
    left, lane_width = 150, 1_220
    sample_count = int(manifest["timeline"]["sampleCount"])
    pieces = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas_width}" height="{canvas_height}" viewBox="0 0 {canvas_width} {canvas_height}">',
        '<rect width="100%" height="100%" fill="#0f172a"/>',
        '<style>text{font-family:-apple-system,BlinkMacSystemFont,sans-serif;fill:#e2e8f0;font-size:12px}.label{font-weight:600}.minor{fill:#94a3b8;font-size:10px}</style>',
        f'<text x="16" y="24" class="label">{escape(str(manifest["prID"]))}</text>',
    ]
    lanes = (("waveform RMS (not stored)", 55), ("VAD probability", 115), ("VAD speech", 175), ("words", 235), ("phones", 295), ("final poses", 355))
    for label, y in lanes:
        pieces.append(f'<text x="16" y="{y + 20}" class="label">{escape(label)}</text>')
        pieces.append(f'<rect x="{left}" y="{y}" width="{lane_width}" height="40" fill="#1e293b" stroke="#334155"/>')
    pieces.append(f'<text x="{left + 8}" y="79" class="minor">Diagnostic waveform samples are intentionally absent from shipped manifests.</text>')

    if vad is not None:
        points: list[str] = []
        for window in vad.windows:
            sample48 = window.start_sample_16k * 3
            px = _x(sample48, sample_count, left, lane_width)
            py = 151 - 32 * window.speech_probability
            points.append(f"{px:.2f},{py:.2f}")
        if points:
            pieces.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="#22c55e" stroke-width="1.5"/>')
        for span in vad.speech_spans:
            start = _x(span.start_sample_48k, sample_count, left, lane_width)
            end = _x(span.end_sample_48k, sample_count, left, lane_width)
            pieces.append(f'<rect x="{start:.2f}" y="180" width="{max(.5, end-start):.2f}" height="30" fill="#22c55e" opacity=".8"/>')

    if alignment is not None:
        for word in alignment.words:
            start = _x(word.start_sample, sample_count, left, lane_width)
            end = _x(word.end_sample, sample_count, left, lane_width)
            pieces.append(f'<rect x="{start:.2f}" y="240" width="{max(.5, end-start):.2f}" height="28" fill="#0ea5e9" opacity=".75"/>')
            if end - start > 20:
                pieces.append(f'<text x="{start+2:.2f}" y="258" class="minor">{escape(word.label)}</text>')
        for phone in alignment.phones:
            start = _x(phone.start_sample, sample_count, left, lane_width)
            end = _x(phone.end_sample, sample_count, left, lane_width)
            pieces.append(f'<rect x="{start:.2f}" y="300" width="{max(.5, end-start):.2f}" height="28" fill="#ec4899" opacity=".7"/>')
            if end - start > 12:
                pieces.append(f'<text x="{start+1:.2f}" y="318" class="minor">{escape(phone.raw_phone)}</text>')

    frames = manifest["frames"]
    run_start = 0
    for index in range(1, len(frames) + 1):
        if index == len(frames) or frames[index]["pose"] != frames[run_start]["pose"]:
            first, last = frames[run_start], frames[index - 1]
            start = _x(int(first["sampleStart"]), sample_count, left, lane_width)
            end = _x(int(last["sampleEnd"]), sample_count, left, lane_width)
            pose = str(first["pose"])
            pieces.append(f'<rect x="{start:.2f}" y="360" width="{max(.5, end-start):.2f}" height="28" fill="{_POSE_COLORS[pose]}"/>')
            run_start = index
    legend_x = left
    for pose, color in _POSE_COLORS.items():
        pieces.append(f'<rect x="{legend_x}" y="402" width="12" height="12" fill="{color}"/><text x="{legend_x+17}" y="413">{pose}</text>')
        legend_x += 115
    pieces.append("</svg>\n")
    return "".join(pieces)
