from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any

from .config import CompilerPaths
from .hashing import sha256_file
from .registry import EligiblePR


@dataclass(frozen=True, slots=True)
class AuthoredPRDescriptor:
    pr_id: str
    descriptor_path: Path
    descriptor_resource_path: str
    descriptor_sha256: str
    speaker_character_id: str
    interaction_surface: str
    transcript_mode: str
    transcript: str
    audio_file: str
    raw: dict[str, Any]


def _effective_surface(pr_id: str) -> str:
    if ".walkie." in pr_id:
        return "walkie"
    if ".hamReceiver." in pr_id:
        return "hamReceiver"
    if ".crankRadio." in pr_id:
        return "crankRadio"
    if ".dadFrame." in pr_id or ".dadPhoto" in pr_id:
        return "dadFrame"
    raise ValueError(f"Descriptor ID has no supported effective surface: {pr_id}")


def _read_descriptor(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Descriptor must be a JSON object: {path}")
    return value


def resolve_descriptor(pr_id: str, paths: CompilerPaths = CompilerPaths()) -> AuthoredPRDescriptor:
    exact = paths.descriptor_root / f"{pr_id}.json"
    candidates: list[tuple[Path, dict[str, Any]]] = []
    if exact.is_file():
        candidates.append((exact, _read_descriptor(exact)))
    else:
        for path in sorted(paths.descriptor_root.glob("*.json")):
            raw = _read_descriptor(path)
            if raw.get("prerecordingID") == pr_id:
                candidates.append((path, raw))
    if len(candidates) != 1:
        raise ValueError(f"Expected one descriptor for {pr_id}, found {len(candidates)}")
    path, raw = candidates[0]
    canonical_id = str(raw.get("prerecordingID", ""))
    if canonical_id != pr_id:
        raise ValueError(f"Descriptor ID mismatch for {pr_id}: {canonical_id}")
    return AuthoredPRDescriptor(
        pr_id=canonical_id,
        descriptor_path=path,
        descriptor_resource_path=(
            "Turing/Prerecordings/" + path.name
        ),
        descriptor_sha256=sha256_file(path),
        speaker_character_id=str(raw.get("speaker", "")),
        interaction_surface=_effective_surface(canonical_id),
        transcript_mode=str(raw.get("transcriptMode", "")),
        transcript=str(raw.get("transcript", "")),
        audio_file=str(raw.get("audioFile", "")),
        raw=raw,
    )


def reconcile_descriptor(entry: EligiblePR, descriptor: AuthoredPRDescriptor) -> Path:
    mismatches: list[str] = []
    for label, expected, actual in (
        ("prID", entry.pr_id, descriptor.pr_id),
        ("speaker", entry.speaker_character_id, descriptor.speaker_character_id),
        ("surface", entry.interaction_surface, descriptor.interaction_surface),
        ("audioFile", entry.audio_file, descriptor.audio_file),
    ):
        if expected != actual:
            mismatches.append(f"{label}: registry={expected!r} descriptor={actual!r}")
    if descriptor.transcript_mode != "manual":
        mismatches.append(f"transcriptMode={descriptor.transcript_mode!r}, expected 'manual'")
    if not descriptor.transcript.strip():
        mismatches.append("transcript is empty")
    if mismatches:
        raise ValueError(f"Descriptor mismatch for {entry.pr_id}: " + "; ".join(mismatches))
    return descriptor.descriptor_path
