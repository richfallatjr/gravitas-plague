from __future__ import annotations

from collections import Counter
import hashlib
import math
from pathlib import Path, PurePosixPath
import re
from typing import Any, Mapping, Sequence

from .config import CONFIG_ROOT
from .constants import REQUIRED_POSES
from .deterministic_json import write_atomic_json
from .hashing import sha256_file
from .registry import EligibilityRegistry, load_registry
from .validator import validate_manifest_file


INDEX_SCHEMA_VERSION = 1
SET_VERSION = "mind-eye-authored-frame-set/1"
EXPECTED_MANIFEST_COUNT = 37
RESOURCE_PREFIX = "Turing/MindsEye/AudioFrames/"
SPEAKER_ORDER = ("big_mike", "rich", "broadcaster", "cateye81", "dad")
SURFACE_ORDER = ("walkie", "dadFrame", "crankRadio", "hamReceiver")
POSE_ORDER = tuple(pose.value for pose in REQUIRED_POSES)
EXPECTED_SPEAKER_COUNTS = {
    "big_mike": 10,
    "rich": 15,
    "broadcaster": 5,
    "cateye81": 5,
    "dad": 2,
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def expected_manifest_filenames(
    registry: EligibilityRegistry | None = None,
) -> tuple[str, ...]:
    registry = registry or load_registry()
    return tuple(f"{entry.pr_id}.mouthframes.json" for entry in registry.entries)


def manifest_set_sha256(directory: Path, filenames: Sequence[str]) -> str:
    digest = hashlib.sha256()
    for filename in sorted(filenames):
        path = directory / filename
        resource_path = f"{RESOURCE_PREFIX}{filename}"
        digest.update(resource_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(path.stat().st_size).encode("ascii"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _pose_counts(manifest: Mapping[str, Any]) -> dict[str, int]:
    source = manifest["summary"]["poseFrameCounts"]
    return {pose: int(source[pose]) for pose in POSE_ORDER}


def build_index_payload(
    directory: Path,
    *,
    registry: EligibilityRegistry | None = None,
    verify_sources: bool = True,
) -> dict[str, Any]:
    registry = registry or load_registry()
    expected = expected_manifest_filenames(registry)
    actual = tuple(sorted(path.name for path in directory.glob("*.mouthframes.json")))
    if len(actual) != EXPECTED_MANIFEST_COUNT or set(actual) != set(expected):
        raise ValueError(
            "Cannot build index for an incomplete production set; "
            f"missing={sorted(set(expected) - set(actual))} "
            f"orphan={sorted(set(actual) - set(expected))}"
        )

    decoded: list[tuple[Path, dict[str, Any], str]] = []
    for filename in actual:
        path = directory / filename
        payload = validate_manifest_file(path, verify_sources=verify_sources)
        if filename != f"{payload['prID']}.mouthframes.json":
            raise ValueError(f"Manifest filename/PR ID mismatch: {filename}")
        decoded.append((path, payload, sha256_file(path)))

    hashes = [item[2] for item in decoded]
    if len(set(hashes)) != len(hashes):
        raise ValueError("Production manifests must have unique full-file hashes")
    global_fields = (
        "compilerVersion",
        "toolchainLockSHA256",
        "compilerConfigSHA256",
        "phonemePoseMapSHA256",
        "pronunciationOverridesSHA256",
    )
    baseline = decoded[0][1]
    baseline_provenance = baseline["analysisProvenance"]
    for _, manifest, _ in decoded[1:]:
        if manifest["compilerVersion"] != baseline["compilerVersion"]:
            raise ValueError("Mixed compiler versions in production set")
        provenance = manifest["analysisProvenance"]
        for key in global_fields[1:]:
            if provenance[key] != baseline_provenance[key]:
                raise ValueError(f"Mixed production provenance: {key}")
        for key in ("version", "acousticModel", "acousticModelVersion", "dictionary", "dictionaryVersion", "g2pModel", "g2pModelVersion"):
            if provenance["mfa"][key] != baseline_provenance["mfa"][key]:
                raise ValueError(f"Mixed MFA provenance: {key}")
        for key in ("name", "version", "backend", "modelSHA256", "configurationSHA256"):
            if provenance["vad"][key] != baseline_provenance["vad"][key]:
                raise ValueError(f"Mixed VAD provenance: {key}")

    entries: list[dict[str, Any]] = []
    for path, manifest, manifest_hash in sorted(decoded, key=lambda item: str(item[1]["prID"])):
        timeline = manifest["timeline"]
        summary = manifest["summary"]
        entries.append({
            "prID": manifest["prID"],
            "speakerCharacterID": manifest["speakerCharacterID"],
            "interactionSurface": manifest["interactionSurface"],
            "manifestResourcePath": f"{RESOURCE_PREFIX}{path.name}",
            "manifestSHA256": manifest_hash,
            "descriptorSHA256": manifest["descriptorSHA256"],
            "audioSHA256": manifest["audioSHA256"],
            "transcriptSHA256": manifest["transcriptSHA256"],
            "sampleCount": timeline["sampleCount"],
            "frameCount": timeline["frameCount"],
            "durationSeconds": timeline["durationSeconds"],
            "poseFrameCounts": _pose_counts(manifest),
            "speechFrameCount": summary["speechFrameCount"],
            "fallbackFrameCount": summary["fallbackFrameCount"],
            "manualOverrideFrameCount": summary["manualOverrideFrameCount"],
            "warningCount": len(summary["warnings"]),
        })

    speaker_counts = Counter(str(entry["speakerCharacterID"]) for entry in entries)
    surface_counts = Counter(str(entry["interactionSurface"]) for entry in entries)
    aggregate_pose_counts = {
        pose: sum(int(entry["poseFrameCounts"][pose]) for entry in entries)
        for pose in POSE_ORDER
    }
    if dict(speaker_counts) != EXPECTED_SPEAKER_COUNTS:
        raise ValueError(f"Production speaker counts are invalid: {dict(speaker_counts)}")
    if any(aggregate_pose_counts[pose] <= 0 for pose in POSE_ORDER):
        raise ValueError("All five poses must be represented in the complete corpus")

    total_samples = sum(int(entry["sampleCount"]) for entry in entries)
    payload = {
        "schemaVersion": INDEX_SCHEMA_VERSION,
        "setVersion": SET_VERSION,
        "compilerVersion": baseline["compilerVersion"],
        "expectedManifestCount": EXPECTED_MANIFEST_COUNT,
        "manifestSetSHA256": manifest_set_sha256(directory, actual),
        "registrySHA256": sha256_file(CONFIG_ROOT / "eligible_authored_prs.json"),
        "toolchainLockSHA256": baseline_provenance["toolchainLockSHA256"],
        "compilerConfigSHA256": baseline_provenance["compilerConfigSHA256"],
        "phonemePoseMapSHA256": baseline_provenance["phonemePoseMapSHA256"],
        "pronunciationOverridesSHA256": baseline_provenance["pronunciationOverridesSHA256"],
        "entries": entries,
        "summary": {
            "manifestCount": EXPECTED_MANIFEST_COUNT,
            "speakerManifestCounts": {
                key: speaker_counts.get(key, 0) for key in SPEAKER_ORDER
            },
            "surfaceManifestCounts": {
                key: surface_counts.get(key, 0) for key in SURFACE_ORDER
            },
            "totalSampleCount": total_samples,
            "totalFrameCount": sum(int(entry["frameCount"]) for entry in entries),
            "totalDurationSeconds": round(total_samples / 48_000, 9),
            "aggregatePoseFrameCounts": aggregate_pose_counts,
            "totalSpeechFrameCount": sum(int(entry["speechFrameCount"]) for entry in entries),
            "totalFallbackFrameCount": sum(int(entry["fallbackFrameCount"]) for entry in entries),
            "totalManualOverrideFrameCount": sum(int(entry["manualOverrideFrameCount"]) for entry in entries),
            "totalWarningCount": sum(int(entry["warningCount"]) for entry in entries),
            "manifestBytes": sum(path.stat().st_size for path, _, _ in decoded),
        },
    }
    validate_index_object(payload)
    return payload


def write_index(directory: Path, output: Path) -> dict[str, Any]:
    payload = build_index_payload(directory)
    write_atomic_json(output, payload)
    return payload


def _require_exact_keys(value: Mapping[str, Any], keys: Sequence[str], label: str) -> None:
    if tuple(value) != tuple(keys):
        raise ValueError(f"{label} keys/order mismatch")


def _require_sha(value: Any, label: str) -> None:
    if not isinstance(value, str) or not SHA256_PATTERN.fullmatch(value):
        raise ValueError(f"{label} must be a lowercase SHA-256")


def validate_index_object(payload: Mapping[str, Any]) -> None:
    _require_exact_keys(payload, (
        "schemaVersion", "setVersion", "compilerVersion", "expectedManifestCount",
        "manifestSetSHA256", "registrySHA256", "toolchainLockSHA256",
        "compilerConfigSHA256", "phonemePoseMapSHA256",
        "pronunciationOverridesSHA256", "entries", "summary",
    ), "index")
    if payload["schemaVersion"] != 1 or payload["setVersion"] != SET_VERSION:
        raise ValueError("Unsupported authored frame index schema/set version")
    if payload["expectedManifestCount"] != EXPECTED_MANIFEST_COUNT:
        raise ValueError("Index expectedManifestCount must be 37")
    for key in (
        "manifestSetSHA256", "registrySHA256", "toolchainLockSHA256",
        "compilerConfigSHA256", "phonemePoseMapSHA256",
        "pronunciationOverridesSHA256",
    ):
        _require_sha(payload[key], key)
    entries = payload["entries"]
    if not isinstance(entries, list) or len(entries) != EXPECTED_MANIFEST_COUNT:
        raise ValueError("Index must contain exactly 37 entries")
    ids: list[str] = []
    paths: list[str] = []
    hashes: list[str] = []
    for index, raw in enumerate(entries):
        if not isinstance(raw, dict):
            raise ValueError(f"entries[{index}] must be an object")
        _require_exact_keys(raw, (
            "prID", "speakerCharacterID", "interactionSurface", "manifestResourcePath",
            "manifestSHA256", "descriptorSHA256", "audioSHA256", "transcriptSHA256",
            "sampleCount", "frameCount", "durationSeconds", "poseFrameCounts",
            "speechFrameCount", "fallbackFrameCount", "manualOverrideFrameCount", "warningCount",
        ), f"entries[{index}]")
        pr_id = raw["prID"]
        resource = raw["manifestResourcePath"]
        if not isinstance(pr_id, str) or not pr_id:
            raise ValueError(f"entries[{index}].prID is invalid")
        if raw["speakerCharacterID"] not in SPEAKER_ORDER or raw["interactionSurface"] not in SURFACE_ORDER:
            raise ValueError(f"entries[{index}] speaker/surface is invalid")
        if not isinstance(resource, str) or not resource.startswith(RESOURCE_PREFIX):
            raise ValueError(f"entries[{index}].manifestResourcePath is unsafe")
        pure = PurePosixPath(resource)
        if pure.is_absolute() or ".." in pure.parts or pure.name != f"{pr_id}.mouthframes.json":
            raise ValueError(f"entries[{index}].manifestResourcePath does not match its PR ID")
        for key in ("manifestSHA256", "descriptorSHA256", "audioSHA256", "transcriptSHA256"):
            _require_sha(raw[key], f"entries[{index}].{key}")
        for key in ("sampleCount", "frameCount"):
            if not isinstance(raw[key], int) or isinstance(raw[key], bool) or raw[key] <= 0:
                raise ValueError(f"entries[{index}].{key} must be positive")
        for key in ("speechFrameCount", "fallbackFrameCount", "manualOverrideFrameCount", "warningCount"):
            if not isinstance(raw[key], int) or isinstance(raw[key], bool) or raw[key] < 0:
                raise ValueError(f"entries[{index}].{key} must be nonnegative")
        duration = raw["durationSeconds"]
        if not isinstance(duration, (int, float)) or isinstance(duration, bool) or not math.isfinite(float(duration)):
            raise ValueError(f"entries[{index}].durationSeconds must be finite")
        if abs(float(duration) - raw["sampleCount"] / 48_000) > 0.5 / 48_000:
            raise ValueError(f"entries[{index}].durationSeconds is inconsistent")
        poses = raw["poseFrameCounts"]
        if not isinstance(poses, dict) or tuple(poses) != POSE_ORDER:
            raise ValueError(f"entries[{index}].poseFrameCounts is invalid")
        if any(not isinstance(poses[pose], int) or isinstance(poses[pose], bool) or poses[pose] < 0 for pose in POSE_ORDER):
            raise ValueError(f"entries[{index}].poseFrameCounts contains invalid counts")
        if sum(poses.values()) != raw["frameCount"]:
            raise ValueError(f"entries[{index}] pose counts do not equal frame count")
        ids.append(pr_id)
        paths.append(resource)
        hashes.append(raw["manifestSHA256"])
    if ids != sorted(ids) or len(set(ids)) != len(ids) or len(set(paths)) != len(paths) or len(set(hashes)) != len(hashes):
        raise ValueError("Index entries must be sorted with unique IDs, paths, and hashes")

    summary = payload["summary"]
    if not isinstance(summary, dict):
        raise ValueError("Index summary must be an object")
    _require_exact_keys(summary, (
        "manifestCount", "speakerManifestCounts", "surfaceManifestCounts",
        "totalSampleCount", "totalFrameCount", "totalDurationSeconds",
        "aggregatePoseFrameCounts", "totalSpeechFrameCount",
        "totalFallbackFrameCount", "totalManualOverrideFrameCount",
        "totalWarningCount", "manifestBytes",
    ), "summary")
    if summary["manifestCount"] != EXPECTED_MANIFEST_COUNT:
        raise ValueError("Index summary manifestCount must be 37")
    if summary["speakerManifestCounts"] != EXPECTED_SPEAKER_COUNTS:
        raise ValueError("Index speaker counts are invalid")
    if not isinstance(summary["surfaceManifestCounts"], dict) or tuple(summary["surfaceManifestCounts"]) != SURFACE_ORDER:
        raise ValueError("Index surface counts are invalid")
    if not isinstance(summary["aggregatePoseFrameCounts"], dict) or tuple(summary["aggregatePoseFrameCounts"]) != POSE_ORDER:
        raise ValueError("Index aggregate pose counts are invalid")
    if any(summary["aggregatePoseFrameCounts"][pose] <= 0 for pose in POSE_ORDER):
        raise ValueError("All five aggregate poses must be present")
