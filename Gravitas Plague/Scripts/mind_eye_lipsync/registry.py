from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import json
from pathlib import Path
import re

from .config import CONFIG_ROOT


_SAFE_ID = re.compile(r"^[A-Za-z0-9._-]+$")
_SPEAKER_COUNTS = {
    "big_mike": 10,
    "rich": 15,
    "broadcaster": 5,
    "cateye81": 5,
    "dad": 2,
}
_SURFACES = {"walkie", "dadFrame", "crankRadio", "hamReceiver"}
_ROLES = {"primary", "authoredBridge"}


@dataclass(frozen=True, slots=True)
class EligiblePR:
    pr_id: str
    speaker_character_id: str
    interaction_surface: str
    audio_file: str
    role: str


@dataclass(frozen=True, slots=True)
class ExcludedPR:
    pr_id: str
    reason: str


@dataclass(frozen=True, slots=True)
class EligibilityRegistry:
    schema_version: int
    expected_eligible_count: int
    entries: tuple[EligiblePR, ...]
    exclusions: tuple[ExcludedPR, ...]

    def require_entry(self, pr_id: str) -> EligiblePR:
        matches = [entry for entry in self.entries if entry.pr_id == pr_id]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one eligible entry for {pr_id}.")
        return matches[0]

    @property
    def excluded_ids(self) -> frozenset[str]:
        return frozenset(item.pr_id for item in self.exclusions)


def _safe_audio_filename(value: str) -> bool:
    return (
        bool(value)
        and Path(value).name == value
        and value.lower().endswith(".mp3")
        and "\0" not in value
        and "/" not in value
        and "\\" not in value
    )


def load_registry(path: Path | None = None) -> EligibilityRegistry:
    path = path or CONFIG_ROOT / "eligible_authored_prs.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    entries = tuple(
        EligiblePR(
            pr_id=str(item["prID"]),
            speaker_character_id=str(item["speakerCharacterID"]),
            interaction_surface=str(item["interactionSurface"]),
            audio_file=str(item["audioFile"]),
            role=str(item["role"]),
        )
        for item in payload.get("entries", [])
    )
    exclusions = tuple(
        ExcludedPR(pr_id=str(item["prID"]), reason=str(item["reason"]))
        for item in payload.get("exclusions", [])
    )
    registry = EligibilityRegistry(
        schema_version=int(payload.get("schemaVersion", 0)),
        expected_eligible_count=int(payload.get("expectedEligibleCount", 0)),
        entries=entries,
        exclusions=exclusions,
    )
    validate_registry(registry)
    return registry


def validate_registry(registry: EligibilityRegistry) -> None:
    if registry.schema_version != 1:
        raise ValueError("Registry schemaVersion must be 1")
    if registry.expected_eligible_count != 37 or len(registry.entries) != 37:
        raise ValueError("Registry must contain exactly 37 eligible entries")
    if len(registry.exclusions) != 8:
        raise ValueError("Registry must contain exactly eight exclusions")
    entry_ids = [item.pr_id for item in registry.entries]
    exclusion_ids = [item.pr_id for item in registry.exclusions]
    if len(set(entry_ids)) != len(entry_ids) or len(set(exclusion_ids)) != len(exclusion_ids):
        raise ValueError("Registry IDs must be unique")
    overlap = set(entry_ids) & set(exclusion_ids)
    if overlap:
        raise ValueError(f"Registry entry/exclusion overlap: {sorted(overlap)}")
    for item in registry.entries:
        if not _SAFE_ID.fullmatch(item.pr_id):
            raise ValueError(f"Unsafe PR ID: {item.pr_id}")
        if item.speaker_character_id not in _SPEAKER_COUNTS:
            raise ValueError(f"Unknown speaker: {item.speaker_character_id}")
        if item.interaction_surface not in _SURFACES:
            raise ValueError(f"Unknown interaction surface: {item.interaction_surface}")
        if item.role not in _ROLES:
            raise ValueError(f"Unknown authored role: {item.role}")
        if not _safe_audio_filename(item.audio_file):
            raise ValueError(f"Unsafe audio filename: {item.audio_file}")
    for item in registry.exclusions:
        if not _SAFE_ID.fullmatch(item.pr_id) or not item.reason.strip():
            raise ValueError(f"Invalid exclusion: {item.pr_id}")
    counts = Counter(item.speaker_character_id for item in registry.entries)
    if dict(counts) != _SPEAKER_COUNTS:
        raise ValueError(f"Registry speaker counts mismatch: {dict(counts)}")
