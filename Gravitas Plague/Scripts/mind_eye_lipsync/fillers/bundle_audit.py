from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .registry import sha256_file


AUDIO_EXTENSIONS = {".mp3", ".wav", ".m4a", ".aiff", ".caf"}


def audit_bundle(bundle: Path) -> dict[str, Any]:
    filler_root = bundle / "Turing" / "MindsEye" / "Fillers"
    index_path = filler_root / "index.json"
    if not index_path.is_file():
        raise ValueError("Built bundle is missing the filler index")
    index = json.loads(index_path.read_text(encoding="utf-8"))
    entries = index.get("entries", [])
    tracks = list((filler_root / "Tracks").glob("*.fillerframes.json"))
    if len(entries) != 51 or len(tracks) != 51:
        raise ValueError("Built bundle must contain one index and exactly 51 filler tracks")

    authored_root = bundle / "Turing" / "MindsEye" / "AudioFrames"
    authored_indices = list(authored_root.glob("index.json"))
    authored_tracks = list(authored_root.glob("*.mouthframes.json"))
    if len(authored_indices) != 1 or len(authored_tracks) != 37:
        raise ValueError("Built bundle changed the 37-track authored PR corpus")

    mind_eye_audio = [
        path for path in (bundle / "Turing" / "MindsEye").rglob("*")
        if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS
    ]
    if mind_eye_audio:
        raise ValueError("Built bundle contains duplicated audio under Turing/MindsEye")

    all_audio = [
        path for path in bundle.rglob("*")
        if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS
    ]
    hashes: dict[str, int] = {}
    for path in all_audio:
        digest = sha256_file(path)
        hashes[digest] = hashes.get(digest, 0) + 1
    for entry in entries:
        expected = bundle / entry["audioResourcePath"]
        if not expected.is_file():
            raise ValueError(f"Built bundle is missing filler audio: {entry['fillerID']}")
        if sha256_file(expected) != entry["audioSHA256"]:
            raise ValueError(f"Built filler audio hash mismatch: {entry['fillerID']}")
        if hashes.get(entry["audioSHA256"], 0) != 1:
            raise ValueError(f"Built filler audio is duplicated: {entry['fillerID']}")

    forbidden = []
    for path in bundle.rglob("*"):
        lowered = path.name.lower()
        if path.is_file() and (
            path.suffix.lower() in {".html", ".svg", ".textgrid"}
            or lowered.endswith("timeline.wav")
            or "filler_descriptors" in lowered
        ):
            forbidden.append(path)
    if forbidden:
        raise ValueError(f"Built bundle contains authoring debris: {forbidden[0]}")
    return {
        "status": "PASS",
        "fillerAudioCount": 51,
        "fillerTrackCount": 51,
        "authoredTrackCount": 37,
        "duplicateFillerAudioCount": 0,
        "authoringDebrisCount": 0,
    }
