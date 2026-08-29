from __future__ import annotations

import hashlib
import json
from collections import Counter
from pathlib import Path
from typing import Any

from ..config import RESOURCES_ROOT
from .pose_runs import POSE_BITS
from .registry import sha256_file


def load_and_validate_track(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    validate_track(payload)
    return payload


def validate_track(payload: dict[str, Any]) -> None:
    if payload.get("schemaVersion") != 1:
        raise ValueError("Unsupported filler track schemaVersion")
    if payload.get("trackVersion") != "mind-eye-filler-track/1":
        raise ValueError("Unsupported filler trackVersion")
    if payload.get("mouthLayerBits") != POSE_BITS:
        raise ValueError("Filler track must declare all five canonical mouth poses")

    timeline = payload.get("timeline", {})
    sample_count = timeline.get("sampleCount")
    frame_count = timeline.get("frameCount")
    if timeline.get("sampleRate") != 48_000 or timeline.get("framesPerSecond") != 60:
        raise ValueError("Filler track timeline must be 48 kHz at 60 fps")
    if timeline.get("samplesPerNominalFrame") != 800:
        raise ValueError("Filler track must use 800 samples per nominal frame")
    if not isinstance(sample_count, int) or sample_count < 1:
        raise ValueError("Filler track sampleCount must be positive")
    if frame_count != (sample_count + 799) // 800:
        raise ValueError("Filler frameCount does not cover the exact PCM timeline")

    cursor = 0
    prior_pose: str | None = None
    expanded = bytearray()
    pose_counts: Counter[str] = Counter()
    for run in payload.get("poseRuns", []):
        pose = run.get("pose")
        start = run.get("startFrame")
        end = run.get("endFrameExclusive")
        evidence = run.get("evidenceMask")
        if pose not in POSE_BITS:
            raise ValueError(f"Unknown filler pose: {pose}")
        if start != cursor or not isinstance(end, int) or end <= cursor:
            raise ValueError("Filler pose runs must be positive and contiguous")
        if pose == prior_pose:
            raise ValueError("Adjacent filler pose runs must be compacted")
        if not isinstance(evidence, int) or not 0 <= evidence <= 127:
            raise ValueError("Filler evidenceMask is outside the seven-bit contract")
        length = end - cursor
        expanded.extend([POSE_BITS[pose]] * length)
        pose_counts[pose] += length
        cursor = end
        prior_pose = pose
    if cursor != frame_count:
        raise ValueError("Filler pose runs do not cover the exact frame timeline")
    if hashlib.sha256(expanded).hexdigest() != payload.get("expandedFramesSHA256"):
        raise ValueError("Filler expanded-frame hash mismatch")

    summary_counts = payload.get("summary", {}).get("poseFrameCounts", {})
    if dict(pose_counts) != summary_counts:
        raise ValueError("Filler pose summary does not match sparse runs")
    authoring = payload.get("authoring", {})
    mode = authoring.get("mode")
    provenance = payload.get("analysisProvenance", {})
    if mode == "manualTranscript":
        if not authoring.get("transcriptSHA256") or not provenance.get("mfaRawOutputSHA256"):
            raise ValueError("Manual filler track is missing transcript/MFA provenance")
        if authoring.get("nonverbalProfile") is not None:
            raise ValueError("Manual filler track cannot declare a nonverbal profile")
    elif mode == "nonverbal":
        if not authoring.get("nonverbalProfile"):
            raise ValueError("Nonverbal filler track is missing its profile")
        if not provenance.get("nonverbalConfigurationSHA256"):
            raise ValueError("Nonverbal filler track is missing analyzer provenance")
        if provenance.get("mfaRawOutputSHA256") is not None:
            raise ValueError("Nonverbal filler track cannot contain MFA provenance")
    else:
        raise ValueError("Unknown filler authoring mode")


def validate_set(root: Path, expected_unique_count: int = 51) -> dict[str, Any]:
    index_path = root / "index.json"
    if not index_path.is_file():
        raise ValueError("Filler set is missing index.json")
    index = json.loads(index_path.read_text(encoding="utf-8"))
    if index.get("schemaVersion") != 1 or index.get("indexVersion") != "mind-eye-filler-index/1":
        raise ValueError("Unsupported filler index")
    entries = index.get("entries", [])
    tracks = sorted((root / "Tracks").glob("*.fillerframes.json"))
    if len(entries) != expected_unique_count or len(tracks) != expected_unique_count:
        raise ValueError(
            f"Filler set must contain exactly {expected_unique_count} entries and tracks"
        )
    entry_ids = {entry.get("fillerID") for entry in entries}
    track_ids = {path.name.removesuffix(".fillerframes.json") for path in tracks}
    if len(entry_ids) != expected_unique_count or entry_ids != track_ids:
        raise ValueError("Filler index and track identities differ")

    weighted = 0
    track_hashes: list[str] = []
    for entry in entries:
        weight = entry.get("weight")
        if not isinstance(weight, int) or not 1 <= weight <= 100:
            raise ValueError(f"Invalid filler weight: {entry.get('fillerID')}")
        weighted += weight
        audio = RESOURCES_ROOT / entry["audioResourcePath"]
        track = root / "Tracks" / f'{entry["fillerID"]}.fillerframes.json'
        if not audio.is_file() or sha256_file(audio) != entry.get("audioSHA256"):
            raise ValueError(f"Filler audio hash mismatch: {entry['fillerID']}")
        if sha256_file(track) != entry.get("trackSHA256"):
            raise ValueError(f"Filler track hash mismatch: {entry['fillerID']}")
        track_payload = load_and_validate_track(track)
        if track_payload.get("fillerID") != entry["fillerID"]:
            raise ValueError(f"Filler track identity mismatch: {entry['fillerID']}")
        track_hashes.append(entry["trackSHA256"])
    manifest_set_sha = hashlib.sha256("\n".join(track_hashes).encode()).hexdigest()
    if manifest_set_sha != index.get("manifestSetSHA256"):
        raise ValueError("Filler manifest-set hash mismatch")
    if weighted != index.get("summary", {}).get("weightedEntryCount"):
        raise ValueError("Filler weighted total does not match index summary")
    return {
        "status": "PASS",
        "uniqueClipCount": expected_unique_count,
        "weightedEntryCount": weighted,
    }
