from __future__ import annotations

from functools import partial
import html
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote, urlparse

from .config import AUDIO_ROOT
from .deterministic_json import write_atomic_json
from .hashing import sha256_file
from .registry import load_registry
from .set_index import validate_index_object
from .validator import validate_manifest_file


CSS = """
body{background:#101114;color:#eee;font:15px -apple-system,BlinkMacSystemFont,sans-serif;margin:2rem;line-height:1.45}
a{color:#8bd5ff}.card{background:#1c1f24;border:1px solid #343943;border-radius:10px;padding:1rem;margin:1rem 0}
.warn{color:#ffd166}.ok{color:#8ce99a}table{border-collapse:collapse;width:100%}th,td{padding:.45rem;border-bottom:1px solid #343943;text-align:left}
audio{width:100%}.timeline{overflow-x:auto;background:#08090a;padding:.5rem}.pose{font-variant-numeric:tabular-nums}
""".strip() + "\n"

JS = """
document.querySelectorAll('[data-filter]').forEach(input=>input.addEventListener('input',()=>{const q=input.value.toLowerCase();document.querySelectorAll('[data-row]').forEach(row=>row.hidden=!row.textContent.toLowerCase().includes(q));}));
""".strip() + "\n"


def _page(title: str, body: str) -> str:
    return f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width'><title>{html.escape(title)}</title><link rel='stylesheet' href='../review.css'></head><body>{body}<script src='../review.js'></script></body></html>\n"


def build_review_dashboard(
    manifest_directory: Path,
    report_directory: Path,
    output_directory: Path,
    *,
    verify_sources: bool = True,
) -> dict[str, Any]:
    index = json.loads((manifest_directory / "index.json").read_text(encoding="utf-8"))
    validate_index_object(index)
    output_directory.mkdir(parents=True, exist_ok=True)
    per_pr = output_directory / "per-pr"
    per_pr.mkdir(parents=True, exist_ok=True)
    (output_directory / "review.css").write_text(CSS, encoding="utf-8")
    (output_directory / "review.js").write_text(JS, encoding="utf-8")

    registry = load_registry()
    by_id = {entry.pr_id: entry for entry in registry.entries}
    rows: list[str] = []
    review_entries: list[dict[str, Any]] = []
    decisions: list[dict[str, Any]] = []
    for entry in index["entries"]:
        pr_id = entry["prID"]
        manifest_path = manifest_directory / f"{pr_id}.mouthframes.json"
        report_path = report_directory / f"{pr_id}.report.json"
        svg_path = report_directory / f"{pr_id}.report.svg"
        manifest = validate_manifest_file(manifest_path, verify_sources=verify_sources)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        if report.get("manifestSHA256") != sha256_file(manifest_path):
            raise ValueError(f"Review report is stale: {pr_id}")
        audio_filename = by_id[pr_id].audio_file
        warnings = list(manifest["summary"]["warnings"])
        pose_counts = manifest["summary"]["poseFrameCounts"]
        frame_count = manifest["timeline"]["frameCount"]
        pose_percent = {pose: round(100 * pose_counts[pose] / frame_count, 6) for pose in ("rest", "small", "wide", "round", "teeth")}
        review_entry = {
            "prID": pr_id,
            "speakerCharacterID": entry["speakerCharacterID"],
            "interactionSurface": entry["interactionSurface"],
            "audioFilename": audio_filename,
            "audioURL": f"/audio/{quote(audio_filename)}",
            "durationSeconds": entry["durationSeconds"],
            "frameCount": frame_count,
            "posePercent": pose_percent,
            "vadSpeechPercent": report["vadSpeechPercent"],
            "warnings": warnings,
            "g2pWords": manifest["summary"]["g2pWords"],
            "fallbackFrameCount": manifest["summary"]["fallbackFrameCount"],
            "manualOverrideFrameCount": manifest["summary"]["manualOverrideFrameCount"],
            "decoderParity": report.get("decoderParity"),
            "manifestSHA256": entry["manifestSHA256"],
        }
        review_entries.append(review_entry)
        decisions.append({
            "prID": pr_id,
            "manifestSHA256": entry["manifestSHA256"],
            "status": "unreviewed",
            "notes": "",
        })
        svg = svg_path.read_text(encoding="utf-8")
        warning_html = "".join(f"<li>{html.escape(value)}</li>" for value in warnings) or "<li class='ok'>None</li>"
        pose_html = " ".join(f"{pose}: {pose_percent[pose]:.2f}%" for pose in pose_percent)
        body = (
            f"<p><a href='../index.html'>← complete corpus</a></p><h1>{html.escape(pr_id)}</h1>"
            f"<div class='card'><b>{html.escape(entry['speakerCharacterID'])}</b> · {html.escape(entry['interactionSurface'])} · {entry['durationSeconds']:.3f}s · {frame_count} frames"
            f"<audio controls preload='metadata' src='/audio/{quote(audio_filename)}'></audio></div>"
            f"<div class='card timeline'>{svg}</div>"
            f"<div class='card pose'>{html.escape(pose_html)}<br>VAD speech: {report['vadSpeechPercent']:.3f}%<br>Fallback: {manifest['summary']['fallbackFrameCount']} · Override: {manifest['summary']['manualOverrideFrameCount']}<br>G2P: {html.escape(', '.join(manifest['summary']['g2pWords']) or 'none')}<br>Decoder parity: {html.escape(json.dumps(report.get('decoderParity'), ensure_ascii=False))}</div>"
            f"<div class='card'><h2>Warnings</h2><ul>{warning_html}</ul><p>Manifest: {html.escape(manifest_path.as_posix())}<br>Report: {html.escape(report_path.as_posix())}</p></div>"
        )
        (per_pr / f"{pr_id}.html").write_text(_page(pr_id, body), encoding="utf-8")
        rows.append(
            f"<tr data-row><td><a href='per-pr/{quote(pr_id)}.html'>{html.escape(pr_id)}</a></td>"
            f"<td>{html.escape(entry['speakerCharacterID'])}</td><td>{html.escape(entry['interactionSurface'])}</td>"
            f"<td>{entry['durationSeconds']:.2f}</td><td class={'warn' if warnings else 'ok'}>{len(warnings)}</td></tr>"
        )

    write_atomic_json(output_directory / "review-data.json", {
        "schemaVersion": 1,
        "manifestSetSHA256": index["manifestSetSHA256"],
        "entries": review_entries,
    })
    ledger = output_directory / "review-decisions.json"
    if not ledger.exists():
        write_atomic_json(ledger, {
            "schemaVersion": 1,
            "manifestSetSHA256": index["manifestSetSHA256"],
            "decisions": decisions,
        })
    index_body = (
        "<h1>Mind’s Eye Phase 7 review</h1><p>Automated artifacts only. Every listening decision remains unreviewed until a human reviews it.</p>"
        "<input data-filter placeholder='Filter PR, speaker, or surface'>"
        "<table><thead><tr><th>PR</th><th>Speaker</th><th>Surface</th><th>Seconds</th><th>Warnings</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )
    (output_directory / "index.html").write_text(
        _page("Mind’s Eye Phase 7 review", index_body).replace("../review.css", "review.css").replace("../review.js", "review.js"),
        encoding="utf-8",
    )
    return {
        "status": "PASS",
        "manifestSetSHA256": index["manifestSetSHA256"],
        "entryCount": len(review_entries),
        "outputDirectory": output_directory.as_posix(),
        "humanListeningReview": "NOT RUN",
    }


class _ReviewHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args: Any, review_root: Path, audio_root: Path, allowed_audio: frozenset[str], **kwargs: Any) -> None:
        self.review_root = review_root.resolve()
        self.audio_root = audio_root.resolve()
        self.allowed_audio = allowed_audio
        super().__init__(*args, directory=self.review_root.as_posix(), **kwargs)

    def translate_path(self, path: str) -> str:
        parsed = urlparse(path).path
        if parsed.startswith("/audio/"):
            name = unquote(parsed[len("/audio/"):])
            if name not in self.allowed_audio or Path(name).name != name:
                return (self.review_root / ".not-found").as_posix()
            return (self.audio_root / name).as_posix()
        return super().translate_path(parsed)


def serve_review(output_directory: Path, *, host: str = "127.0.0.1", port: int = 0) -> None:
    if host not in {"127.0.0.1", "localhost", "::1"}:
        raise ValueError("Review server is local-only unless the implementation is explicitly extended")
    allowed = frozenset(entry.audio_file for entry in load_registry().entries)
    handler = partial(
        _ReviewHandler,
        review_root=output_directory,
        audio_root=AUDIO_ROOT,
        allowed_audio=allowed,
    )
    server = ThreadingHTTPServer((host, port), handler)
    print(f"Mind's Eye review: http://{host}:{server.server_port}/")
    server.serve_forever()
