from __future__ import annotations

import json

from chapter03_angel_visemes.compiler import (
    DEFAULT_DESCRIPTOR,
    DEFAULT_OUTPUT,
    POSE_MULTIPLIERS,
    _compact_runs_hash,
    validate,
)


def test_production_manifest_and_current_sources_validate() -> None:
    manifest = validate(DEFAULT_OUTPUT, verify_sources=True)
    assert manifest["timeline"] == {
        "sampleRate": 48_000,
        "sampleCount": 6_994_565,
        "durationSeconds": 6_994_565 / 48_000,
        "framesPerSecond": 60,
        "samplesPerNominalFrame": 800,
        "frameCount": 8_744,
    }
    assert manifest["summary"]["unknownPhoneCount"] == 0
    assert set(manifest["summary"]["poseFrameCounts"]) == set(POSE_MULTIPLIERS)
    assert all(manifest["summary"]["poseFrameCounts"].values())


def test_manifest_runs_are_compact_hashed_for_swift_parity() -> None:
    manifest = json.loads(DEFAULT_OUTPUT.read_text(encoding="utf-8"))
    assert manifest["runsSHA256"] == _compact_runs_hash(manifest["runs"])
    assert manifest["runs"][0]["startFrame"] == 0
    assert manifest["runs"][-1]["endFrameExclusive"] == 8_744


def test_current_descriptor_requires_transcript_free_allphone() -> None:
    descriptor = json.loads(DEFAULT_DESCRIPTOR.read_text(encoding="utf-8"))
    assert descriptor["id"] == "chapter03.cinematic.angel.lightTunnel.001"
    assert descriptor["transcriptMode"] == "none"
    assert descriptor["transcript"] == ""
