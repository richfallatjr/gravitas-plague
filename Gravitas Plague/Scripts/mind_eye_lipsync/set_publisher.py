from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
from typing import Any

from .config import PROJECT_ROOT, RESOURCES_ROOT
from .deterministic_json import write_atomic_json
from .hashing import deterministic_tree_sha256, sha256_file
from .set_index import expected_manifest_filenames
from .set_validator import validate_set


CANONICAL_TARGET = RESOURCES_ROOT / "Turing" / "MindsEye" / "AudioFrames"


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _copy_verified(source: Path, destination: Path) -> None:
    with source.open("rb") as input_stream, destination.open("xb") as output_stream:
        shutil.copyfileobj(input_stream, output_stream, length=1024 * 1024)
        output_stream.flush()
        os.fsync(output_stream.fileno())
    if sha256_file(source) != sha256_file(destination):
        raise RuntimeError(f"Publication copy hash mismatch: {source.name}")


def _journal_path(set_hash: str) -> Path:
    return PROJECT_ROOT / ".build" / "mind-eye-lipsync" / "phase7" / "publish-journal" / f"{set_hash}.json"


def _write_journal(path: Path, payload: dict[str, Any], state: str) -> None:
    updated = dict(payload)
    updated["state"] = state
    write_atomic_json(path, updated)


def publish_set(
    *,
    candidate: Path,
    comparison_report: Path,
    quality_report: Path,
    target: Path,
    replace_complete_set: bool,
) -> dict[str, Any]:
    if target.resolve() != CANONICAL_TARGET.resolve():
        raise ValueError(f"Phase 7 may publish only to {CANONICAL_TARGET}")
    candidate_validation = validate_set(candidate, verify_sources=True)
    if not candidate_validation.is_valid:
        raise ValueError("Candidate complete-set validation failed")
    index = json.loads((candidate / "index.json").read_text(encoding="utf-8"))
    set_hash = str(index["manifestSetSHA256"])
    comparison = json.loads(comparison_report.read_text(encoding="utf-8"))
    if (
        comparison.get("status") != "PASS"
        or comparison.get("differences") != []
        or comparison.get("leftSetSHA256") != set_hash
        or comparison.get("rightSetSHA256") != set_hash
    ):
        raise ValueError("Candidate A/B comparison is not an exact byte-identical PASS")
    quality = json.loads(quality_report.read_text(encoding="utf-8"))
    if quality.get("valid") is not True or quality.get("hardFailureCount") != 0:
        raise ValueError("Production quality hard gate did not pass")

    target_parent = target.parent
    target_parent.mkdir(parents=True, exist_ok=True)
    if os.stat(candidate).st_dev != os.stat(target_parent).st_dev:
        raise ValueError("Candidate and production target must be on the same filesystem")

    expected_names = set(expected_manifest_filenames()) | {"index.json"}
    prior_state = "absent"
    prior_hash: str | None = None
    recovery_path: Path | None = None
    if target.exists():
        if not target.is_dir() or target.is_symlink():
            raise ValueError("Production target exists but is not a regular directory")
        children = list(target.iterdir())
        if not children:
            prior_state = "empty"
        else:
            unknown = [path for path in children if path.name not in expected_names or path.is_symlink() or path.is_dir()]
            if unknown:
                raise ValueError(f"Production target contains ambiguous owner files: {[path.name for path in unknown]}")
            prior_state = "complete" if {path.name for path in children} == expected_names else "partial"
            prior_hash = deterministic_tree_sha256(target)
            if prior_state == "complete" and not replace_complete_set:
                raise ValueError("A complete set already exists; pass --replace-complete-set to replace it")

    journal_path = _journal_path(set_hash)
    journal = {
        "schemaVersion": 1,
        "target": "Gravitas Plague/TuringResources/Turing/MindsEye/AudioFrames",
        "candidateSetSHA256": set_hash,
        "previousSetSHA256": prior_hash,
        "state": "prepared",
    }
    _write_journal(journal_path, journal, "prepared")

    publish_stage = target_parent / f".AudioFrames.phase7-publish-{set_hash[:12]}"
    if publish_stage.exists():
        raise ValueError(f"An incomplete hidden publish stage requires inspection: {publish_stage}")
    publish_stage.mkdir()
    prior_moved = False
    try:
        for name in sorted(expected_names):
            _copy_verified(candidate / name, publish_stage / name)
        _fsync_directory(publish_stage)
        staged_validation = validate_set(publish_stage, verify_sources=True)
        if not staged_validation.is_valid:
            raise RuntimeError("Same-parent publication stage failed complete-set validation")

        if target.exists():
            if prior_state == "empty":
                target.rmdir()
            else:
                recovery_root = PROJECT_ROOT / ".build" / "mind-eye-lipsync" / "phase7" / "recovery"
                recovery_root.mkdir(parents=True, exist_ok=True)
                recovery_path = recovery_root / (prior_hash or deterministic_tree_sha256(target))
                if recovery_path.exists():
                    raise ValueError(f"Recovery destination already exists: {recovery_path}")
                os.replace(target, recovery_path)
                prior_moved = True
                _write_journal(journal_path, journal, "previousMoved")
        os.replace(publish_stage, target)
        _fsync_directory(target_parent)
        _write_journal(journal_path, journal, "candidatePublished")
        published_validation = validate_set(target, verify_sources=True)
        if not published_validation.is_valid:
            raise RuntimeError("Published set failed post-publication validation")
        _write_journal(journal_path, journal, "verified")
        return {
            "status": "PASS",
            "priorTargetState": prior_state,
            "priorSetSHA256": prior_hash,
            "recoveryPath": recovery_path.as_posix() if recovery_path else None,
            "publishedSetSHA256": set_hash,
            "journal": journal_path.as_posix(),
            "productionFileCount": 38,
        }
    except Exception:
        if target.exists():
            invalid = PROJECT_ROOT / ".build" / "mind-eye-lipsync" / "phase7" / "recovery" / f"invalid-{set_hash}"
            invalid.parent.mkdir(parents=True, exist_ok=True)
            if not invalid.exists():
                os.replace(target, invalid)
        if prior_moved and recovery_path is not None and recovery_path.exists() and not target.exists():
            os.replace(recovery_path, target)
        if publish_stage.exists():
            shutil.rmtree(publish_stage)
        raise

