#!/usr/bin/env python3
"""Dependency-free source/build gate for the fixed Chapter 3 Angel cue."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent.parent
RESOURCE_ROOT = PROJECT_DIR / "TuringResources"
SCRIPT_ROOT = PROJECT_DIR / "Scripts"
CUE = RESOURCE_ROOT / "Turing/Cinematics/Chapter03/Cues/chapter03.cinematic.angel.lightTunnel.001.visemes.json"
DESCRIPTOR = RESOURCE_ROOT / "Turing/Cinematics/Chapter03/pr_angel_01.json"
AUDIO = RESOURCE_ROOT / "Turing/Audio/chapter03/pr-angel-01.mp3"
MODEL_ROOT = RESOURCE_ROOT / "Turing/RuntimeLipSync/pocketsphinx-5.1.1/en-us"
PHONE_MAP = SCRIPT_ROOT / "mind_eye_lipsync/config/phoneme_pose_map.json"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(path.stat().st_size).encode("ascii"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def main() -> int:
    payload = json.loads(CUE.read_text(encoding="utf-8"))
    timeline = payload["timeline"]
    runs = payload["runs"]
    multipliers = {"rest": 1.0, "small": 1.33, "wide": 2.0, "round": 1.5, "teeth": 1.75}
    compact_runs = json.dumps(
        runs, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    assert payload["schemaVersion"] == 1
    assert payload["compilerVersion"] == "chapter03-angel-visemes/1.0.0"
    assert payload["trackID"] == "chapter03.cinematic.angel.lightTunnel.001.visemes"
    assert payload["sourceCinematicID"] == "chapter03.cinematic.angel.lightTunnel.001"
    assert payload["descriptorResourcePath"] == "Turing/Cinematics/Chapter03/pr_angel_01.json"
    assert payload["audioResourcePath"] == "Turing/Audio/chapter03/pr-angel-01.mp3"
    assert payload["descriptorSHA256"] == sha256_file(DESCRIPTOR)
    assert payload["audioSHA256"] == sha256_file(AUDIO)
    assert timeline["sampleRate"] == 48_000
    assert timeline["framesPerSecond"] == 60
    assert timeline["samplesPerNominalFrame"] == 800
    assert timeline["frameCount"] == (timeline["sampleCount"] + 799) // 800
    assert payload["requiredPoseFamilies"] == ["rest", "small", "wide", "round", "teeth"]
    assert payload["densityMultipliers"] == multipliers
    assert payload["runsSHA256"] == hashlib.sha256(compact_runs).hexdigest()
    assert runs[0]["startFrame"] == 0
    assert runs[-1]["endFrameExclusive"] == timeline["frameCount"]
    counts = {pose: 0 for pose in multipliers}
    cursor = 0
    previous_pose = None
    for run in runs:
        assert run["startFrame"] == cursor
        assert run["endFrameExclusive"] > cursor
        assert run["pose"] in counts
        assert run["pose"] != previous_pose
        counts[run["pose"]] += run["endFrameExclusive"] - cursor
        cursor = run["endFrameExclusive"]
        previous_pose = run["pose"]
    assert payload["summary"]["poseFrameCounts"] == counts
    assert payload["summary"]["runCount"] == len(runs)
    assert payload["summary"]["speechFrameCount"] == timeline["frameCount"] - counts["rest"]
    assert payload["summary"]["silenceFrameCount"] == counts["rest"]
    assert payload["alignment"]["mode"] == "pocketsphinxAllPhone"
    assert payload["alignment"]["engine"] == "pocketsphinx"
    assert payload["alignment"]["engineVersion"] == "5.1.1"
    assert payload["alignment"]["transcriptSHA256"] is None
    assert payload["alignment"]["acousticModelSHA256"] == sha256_tree(MODEL_ROOT / "acoustic")
    assert payload["alignment"]["phoneLanguageModelSHA256"] == sha256_file(MODEL_ROOT / "en-us-phone.lm.bin")
    assert payload["alignment"]["phonePoseMapSHA256"] == sha256_file(PHONE_MAP)
    print("PASS validated Chapter 3 Angel viseme cue and current sources")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
