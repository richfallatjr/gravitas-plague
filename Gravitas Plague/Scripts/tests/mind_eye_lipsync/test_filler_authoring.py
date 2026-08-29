from __future__ import annotations

import json
from pathlib import Path
import tempfile

import numpy as np

from mind_eye_lipsync.fillers.inventory import inventory
from mind_eye_lipsync.fillers.nonverbal_analyzer import analyze
from mind_eye_lipsync.fillers.nonverbal_profiles import PROFILES
from mind_eye_lipsync.fillers.publisher import publish_set
from mind_eye_lipsync.fillers.registry import REGISTRY_PATH, load_registry
from mind_eye_lipsync.fillers.validator import validate_set
from mind_eye_lipsync.fillers.weight_parser import parse_weight, unweighted_stem


SCRIPTS = Path(__file__).resolve().parents[2]
FILLER_ROOT = SCRIPTS.parent / "TuringResources" / "Turing" / "MindsEye" / "Fillers"


def test_filler_inventory_is_complete_and_weighted() -> None:
    result = inventory()
    assert result["uniqueClipCount"] == 51
    assert result["weightedEntryCount"] == 252
    assert result["speakerUniqueCounts"] == {"big_mike": 27, "rich": 24}
    assert result["speakerWeightedTotals"] == {"big_mike": 132, "rich": 120}


def test_weight_parser_supports_owner_suffixes_and_stable_identity() -> None:
    assert parse_weight("clip_7.mp3") == 7
    assert parse_weight("clip_weight-10.wav") == 10
    assert parse_weight("clip_weight_8.wav") == 8
    assert parse_weight("clip_w-4.m4a") == 4
    assert parse_weight("clip.mp3") == 1
    assert unweighted_stem("clip_7.mp3") == "clip"
    assert unweighted_stem("clip_weight-10.wav") == "clip"
    assert unweighted_stem("clip_weight_8.wav") == "clip"
    assert unweighted_stem("clip_w-4.m4a") == "clip"


def test_registry_has_no_duplicate_audio_or_ids() -> None:
    clips = load_registry(REGISTRY_PATH)["clips"]
    assert len({item["fillerID"] for item in clips}) == 51
    assert len({item["audioResourcePath"] for item in clips}) == 51


def test_published_tracks_are_sparse_and_contiguous() -> None:
    index = json.loads((FILLER_ROOT / "index.json").read_text())
    assert len(index["entries"]) == 51
    assert index["summary"]["weightedEntryCount"] == 252
    for entry in index["entries"]:
        track = json.loads((SCRIPTS.parent / "TuringResources" / entry["trackResourcePath"]).read_text())
        cursor = 0
        prior = None
        for run in track["poseRuns"]:
            assert run["startFrame"] == cursor
            assert run["endFrameExclusive"] > cursor
            assert run["pose"] != prior
            cursor = run["endFrameExclusive"]
            prior = run["pose"]
        assert cursor == track["timeline"]["frameCount"]


def test_published_set_passes_strict_hash_and_provenance_validation() -> None:
    assert validate_set(FILLER_ROOT) == {
        "status": "PASS",
        "uniqueClipCount": 51,
        "weightedEntryCount": 252,
    }


def test_nonverbal_profiles_map_silence_to_rest_deterministically() -> None:
    silence = np.zeros(4_800, dtype=np.float64)
    for profile in sorted(PROFILES):
        first = analyze(silence, frame_count=6, profile=profile)
        second = analyze(silence, frame_count=6, profile=profile)
        assert first == second
        assert first == (["rest"] * 6, [0] * 6)


def test_staged_publisher_validates_before_and_after_atomic_replacement() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        target = Path(temporary_directory) / "Fillers"
        result = publish_set(FILLER_ROOT, target)
        assert result["status"] == "PASS"
        assert result["tracks"] == 51
        assert validate_set(target)["uniqueClipCount"] == 51
        assert not list(target.parent.glob("Fillers.staging.*"))
        assert not list(target.parent.glob("Fillers.backup.*"))
