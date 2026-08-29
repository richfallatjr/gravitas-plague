from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
from typing import Any

from ..config import RESOURCES_ROOT
from .weight_parser import parse_weight, unweighted_stem

REGISTRY_PATH = Path(__file__).resolve().parents[1] / "config" / "filler_descriptors.json"
AUDIO_ROOT = RESOURCES_ROOT / "Turing" / "Audio"
EXPECTED_UNIQUE = {"big_mike": 27, "rich": 24}
EXPECTED_WEIGHTED = {"big_mike": 132, "rich": 120}

MANUAL_TRANSCRIPTS = {
    "alright-alright-alright": "alright, alright, alright",
    "alright": "alright",
    "clear-01": "clear", "clear-02": "clear", "clear-03": "clear",
    "clear01": "clear", "clear02": "clear",
    "give-me-a-second": "give me a second", "give-me-second": "give me a second",
    "hold-on": "hold on", "hold-up-hold-up": "hold up, hold up",
    "let-me-think": "let me think", "like": "like", "listen": "listen",
    "look": "look", "wait": "wait", "ya-heard": "ya heard",
    "yeah-no": "yeah, no", "you-hear": "you hear", "you-know": "you know",
}


def _profile(name: str) -> str | None:
    if "tongue-click" in name: return "tongueClick"
    if "cough" in name: return "cough"
    if "inhale" in name: return "inhale"
    if "exhale" in name: return "exhale"
    if re.search(r"(?:^|[-_])(hmm|hm|mm)(?:\d+)?(?:$|[-_])", name): return "closedHum"
    if re.search(r"(?:^|[-_])(umm|ugh)(?:\d+)?(?:$|[-_])", name): return "openHesitation"
    return None


def _content_name(file: Path, speaker: str) -> str:
    stem = unweighted_stem(file)
    for prefix in (f"{speaker.replace('_', '-')}-filler_", f"{speaker.replace('_', '-')}-filler-"):
        if stem.startswith(prefix):
            return stem[len(prefix):].replace("_", "-")
    raise ValueError(f"Unexpected filler filename prefix: {file.name}")


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def build_registry_payload() -> dict[str, Any]:
    clips: list[dict[str, Any]] = []
    seen_ids: dict[tuple[str, str], int] = {}
    for speaker, directory in (("big_mike", "big-mike-filler"), ("rich", "rich-filler")):
        folder = AUDIO_ROOT / directory
        for file in sorted(folder.iterdir(), key=lambda item: item.name.lower()):
            if file.suffix.lower() not in {".wav", ".mp3", ".m4a", ".aiff", ".caf"}:
                continue
            name = _content_name(file, speaker)
            key = (speaker, _slug(name))
            ordinal = seen_ids.get(key, 0) + 1
            seen_ids[key] = ordinal
            profile = _profile(name)
            transcript = MANUAL_TRANSCRIPTS.get(name)
            if profile is None and transcript is None:
                raise ValueError(f"Filler needs an explicit transcript/profile: {file.name}")
            authoring = ({"mode": "nonverbal", "profile": profile}
                         if profile else {"mode": "manualTranscript", "transcript": transcript})
            clips.append({
                "fillerID": f"{speaker}.filler.{_slug(name)}.{ordinal:03d}",
                "speakerCharacterID": speaker,
                "audioResourcePath": f"Turing/Audio/{directory}/{file.name}",
                "weight": parse_weight(file),
                "authoring": authoring,
            })
    clips.sort(key=lambda item: item["fillerID"])
    return {
        "schemaVersion": 1,
        "registryVersion": "mind-eye-filler-authoring/1",
        "expectedUniqueClipCounts": EXPECTED_UNIQUE,
        "expectedWeightedTotals": EXPECTED_WEIGHTED,
        "clips": clips,
    }


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, separators=(",", ": ")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def write_registry(path: Path = REGISTRY_PATH) -> dict[str, Any]:
    payload = build_registry_payload()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(payload))
    return payload


def load_registry(path: Path = REGISTRY_PATH) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    validate_registry(payload)
    return payload


def validate_registry(payload: dict[str, Any]) -> None:
    if payload.get("schemaVersion") != 1 or payload.get("registryVersion") != "mind-eye-filler-authoring/1":
        raise ValueError("Unsupported filler registry")
    clips = payload.get("clips")
    if not isinstance(clips, list): raise ValueError("Filler clips must be an array")
    ids, paths = set(), set()
    counts = {key: 0 for key in EXPECTED_UNIQUE}
    totals = {key: 0 for key in EXPECTED_WEIGHTED}
    for clip in clips:
        speaker = clip["speakerCharacterID"]
        if speaker not in counts: raise ValueError(f"Unsupported filler speaker: {speaker}")
        filler_id, resource = clip["fillerID"], clip["audioResourcePath"]
        if filler_id in ids or resource in paths: raise ValueError("Duplicate filler ID/audio path")
        ids.add(filler_id); paths.add(resource)
        path = RESOURCES_ROOT / resource
        if not path.is_file(): raise ValueError(f"Missing filler audio: {resource}")
        if parse_weight(path) != clip["weight"]: raise ValueError(f"Weight mismatch: {resource}")
        authoring = clip.get("authoring", {})
        if authoring.get("mode") == "manualTranscript":
            if not str(authoring.get("transcript", "")).strip(): raise ValueError("Empty filler transcript")
        elif authoring.get("mode") == "nonverbal":
            if authoring.get("profile") not in {"cough", "inhale", "exhale", "tongueClick", "closedHum", "openHesitation"}:
                raise ValueError("Invalid filler nonverbal profile")
        else: raise ValueError("Invalid filler authoring mode")
        counts[speaker] += 1; totals[speaker] += clip["weight"]
    if counts != EXPECTED_UNIQUE or totals != EXPECTED_WEIGHTED:
        raise ValueError(f"Filler inventory mismatch counts={counts} totals={totals}")
    actual = {
        f"Turing/Audio/{directory}/{item.name}"
        for directory in ("big-mike-filler", "rich-filler")
        for item in (AUDIO_ROOT / directory).iterdir()
        if item.suffix.lower() in {".wav", ".mp3", ".m4a", ".aiff", ".caf"}
    }
    if actual != paths: raise ValueError(f"Registry/file mismatch missing={sorted(actual-paths)} stale={sorted(paths-actual)}")
