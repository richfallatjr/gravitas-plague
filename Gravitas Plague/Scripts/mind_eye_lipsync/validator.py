from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path
from pathlib import PurePosixPath
import re
from typing import Any, Mapping, Sequence

from .config import CompilerPaths, load_compiler_configuration
from .constants import (
    BIT_TO_POSE,
    EVIDENCE_FALLBACK,
    EVIDENCE_MANUAL_OVERRIDE,
    POSE_TO_BIT,
    REQUIRED_POSES,
)
from .descriptor_loader import reconcile_descriptor, resolve_descriptor
from .frame_expander import FrameDecision, frames_sha256
from .hashing import sha256_bytes, sha256_file
from .manifest import build_summary
from .registry import EligibilityRegistry, load_registry


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_SUPPORTED_COMPILER = "mind-eye-authored-frame-compiler/1.0.3"
_TOP_LEVEL_KEYS = (
    "schemaVersion", "compilerVersion", "prID", "speakerCharacterID",
    "interactionSurface", "descriptorResourcePath", "descriptorSHA256",
    "audioResourcePath", "audioSHA256", "transcriptSHA256", "timeline",
    "mouthLayerBits", "requiredPoseFamilies", "analysisProvenance",
    "framesSHA256", "frames", "summary",
)


@dataclass(frozen=True, slots=True)
class ValidationResult:
    manifest_count: int
    pr_ids: tuple[str, ...]


def _require_object(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def _require_exact_keys(value: Mapping[str, Any], expected: Sequence[str], label: str) -> None:
    if tuple(value) != tuple(expected):
        missing = sorted(set(expected) - set(value))
        extra = sorted(set(value) - set(expected))
        raise ValueError(f"{label} keys/order mismatch; missing={missing} extra={extra}")


def _require_sha(value: Any, label: str, *, nullable: bool = False) -> None:
    if nullable and value is None:
        return
    if not isinstance(value, str) or not _SHA256.fullmatch(value):
        raise ValueError(f"{label} must be a lowercase SHA-256")


def validate_manifest_object(
    payload: Mapping[str, Any],
    *,
    registry: EligibilityRegistry | None = None,
) -> None:
    _require_exact_keys(payload, _TOP_LEVEL_KEYS, "manifest")
    if payload["schemaVersion"] != 1 or payload["compilerVersion"] != _SUPPORTED_COMPILER:
        raise ValueError("Unsupported authored frame manifest schema/compiler")
    registry = registry or load_registry()
    entry = registry.require_entry(str(payload["prID"]))
    if payload["speakerCharacterID"] != entry.speaker_character_id:
        raise ValueError("Manifest speaker does not match registry")
    if payload["interactionSurface"] != entry.interaction_surface:
        raise ValueError("Manifest interaction surface does not match registry")
    for label in ("descriptorResourcePath", "audioResourcePath"):
        resource = payload[label]
        if not isinstance(resource, str):
            raise ValueError(f"{label} must be a relative resource path")
        pure = PurePosixPath(resource)
        if pure.is_absolute() or ".." in pure.parts or not resource.startswith("Turing/"):
            raise ValueError(f"{label} must be a repository-relative Turing resource path")
    for label in (
        "descriptorSHA256", "audioSHA256", "transcriptSHA256", "framesSHA256"
    ):
        _require_sha(payload[label], label)

    timeline = _require_object(payload["timeline"], "timeline")
    _require_exact_keys(
        timeline,
        ("sampleRate", "sampleCount", "durationSeconds", "framesPerSecond",
         "samplesPerNominalFrame", "frameCount"),
        "timeline",
    )
    if timeline["sampleRate"] != 48_000 or timeline["framesPerSecond"] != 60:
        raise ValueError("Timeline must remain 48 kHz at 60 Hz")
    if timeline["samplesPerNominalFrame"] != 800:
        raise ValueError("Timeline nominal frame must remain 800 samples")
    sample_count = timeline["sampleCount"]
    frame_count = timeline["frameCount"]
    if not isinstance(sample_count, int) or isinstance(sample_count, bool) or sample_count <= 0:
        raise ValueError("Timeline sampleCount must be a positive integer")
    expected_frame_count = (sample_count + 799) // 800
    if not isinstance(frame_count, int) or isinstance(frame_count, bool) or frame_count != expected_frame_count:
        raise ValueError("Timeline frameCount does not cover sampleCount exactly")
    duration = timeline["durationSeconds"]
    if not isinstance(duration, (int, float)) or isinstance(duration, bool):
        raise ValueError("Timeline durationSeconds must be numeric")
    if not math.isfinite(float(duration)) or abs(float(duration) - sample_count / 48_000) > 0.5 / 48_000:
        raise ValueError("Timeline durationSeconds does not match exact sample count")

    expected_bits = {pose.value: POSE_TO_BIT[pose] for pose in REQUIRED_POSES}
    if payload["mouthLayerBits"] != expected_bits:
        raise ValueError("Manifest mouthLayerBits are not the five fixed one-hot values")
    if payload["requiredPoseFamilies"] != [pose.value for pose in REQUIRED_POSES]:
        raise ValueError("Manifest requiredPoseFamilies are not canonical")

    provenance = _require_object(payload["analysisProvenance"], "analysisProvenance")
    _require_exact_keys(
        provenance,
        ("toolchainLockSHA256", "compilerConfigSHA256", "phonemePoseMapSHA256",
         "pronunciationOverridesSHA256", "manualOverrideSHA256", "mfa", "vad"),
        "analysisProvenance",
    )
    for label in (
        "toolchainLockSHA256", "compilerConfigSHA256", "phonemePoseMapSHA256",
        "pronunciationOverridesSHA256",
    ):
        _require_sha(provenance[label], f"analysisProvenance.{label}")
    _require_sha(provenance["manualOverrideSHA256"], "manualOverrideSHA256", nullable=True)
    mfa = _require_object(provenance["mfa"], "analysisProvenance.mfa")
    _require_exact_keys(
        mfa,
        ("version", "acousticModel", "acousticModelVersion", "dictionary",
         "dictionaryVersion", "g2pModel", "g2pModelVersion", "retryUsed",
         "rawOutputSHA256"),
        "analysisProvenance.mfa",
    )
    _require_sha(mfa["rawOutputSHA256"], "analysisProvenance.mfa.rawOutputSHA256")
    expected_mfa = {
        "version": "3.3.9",
        "acousticModel": "english_us_arpa",
        "acousticModelVersion": "3.0.0",
        "dictionary": "english_us_arpa",
        "dictionaryVersion": "3.0.0",
        "g2pModel": "english_us_arpa",
        "g2pModelVersion": "2.0.0a",
    }
    if any(mfa[key] != value for key, value in expected_mfa.items()) or not isinstance(mfa["retryUsed"], bool):
        raise ValueError("Manifest MFA provenance does not match the pinned authoring contract")
    vad = _require_object(provenance["vad"], "analysisProvenance.vad")
    _require_exact_keys(
        vad,
        ("name", "version", "backend", "modelSHA256", "configurationSHA256"),
        "analysisProvenance.vad",
    )
    _require_sha(vad["modelSHA256"], "analysisProvenance.vad.modelSHA256")
    _require_sha(vad["configurationSHA256"], "analysisProvenance.vad.configurationSHA256")
    if (vad["name"], vad["version"], vad["backend"]) != ("silero-vad", "6.2.1", "onnx"):
        raise ValueError("Manifest VAD provenance does not match the pinned ONNX authoring contract")

    raw_frames = payload["frames"]
    if not isinstance(raw_frames, list) or not raw_frames or len(raw_frames) != frame_count:
        raise ValueError("Manifest frames must be nonempty and equal timeline frameCount")
    decisions: list[FrameDecision] = []
    previous_end = 0
    for index, raw in enumerate(raw_frames):
        frame = _require_object(raw, f"frames[{index}]")
        _require_exact_keys(
            frame,
            ("frameIndex", "sampleStart", "sampleEnd", "pose", "layerMask",
             "speechActive", "phone", "evidenceMask"),
            f"frames[{index}]",
        )
        if (
            not isinstance(frame["frameIndex"], int)
            or isinstance(frame["frameIndex"], bool)
            or not isinstance(frame["sampleStart"], int)
            or isinstance(frame["sampleStart"], bool)
            or frame["frameIndex"] != index
            or frame["sampleStart"] != previous_end
        ):
            raise ValueError(f"Frame {index} index/sample continuity is invalid")
        start, end = frame["sampleStart"], frame["sampleEnd"]
        if (
            not isinstance(start, int)
            or isinstance(start, bool)
            or not isinstance(end, int)
            or isinstance(end, bool)
            or end <= start
        ):
            raise ValueError(f"Frame {index} sample interval is invalid")
        expected_length = 800 if index < frame_count - 1 else sample_count - start
        if end - start != expected_length or not 1 <= expected_length <= 800:
            raise ValueError(f"Frame {index} length is invalid")
        try:
            pose = BIT_TO_POSE[int(frame["layerMask"])]
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"Frame {index} layerMask is not one-hot") from error
        if frame["pose"] != pose.value:
            raise ValueError(f"Frame {index} pose/layerMask mismatch")
        if not isinstance(frame["speechActive"], bool):
            raise ValueError(f"Frame {index} speechActive must be boolean")
        phone = frame["phone"]
        evidence = frame["evidenceMask"]
        if not isinstance(phone, str) or len(phone.encode("utf-8")) > 0xFFFF:
            raise ValueError(f"Frame {index} phone is invalid")
        if not isinstance(evidence, int) or isinstance(evidence, bool) or not 0 <= evidence <= 0xFFFF:
            raise ValueError(f"Frame {index} evidenceMask is invalid")
        decisions.append(FrameDecision(index, start, end, pose, frame["layerMask"], frame["speechActive"], phone, evidence))
        previous_end = end
    if previous_end != sample_count or frames_sha256(decisions) != payload["framesSHA256"]:
        raise ValueError("Frame coverage or framesSHA256 is invalid")

    summary = _require_object(payload["summary"], "summary")
    _require_exact_keys(
        summary,
        ("poseFrameCounts", "speechFrameCount", "silenceFrameCount", "fallbackFrameCount",
         "manualOverrideFrameCount", "alignedWordCount", "transcriptTokenCount",
         "oovWords", "g2pWords", "warnings"),
        "summary",
    )
    recomputed = build_summary(
        decisions,
        aligned_word_count=int(summary["alignedWordCount"]),
        transcript_token_count=int(summary["transcriptTokenCount"]),
        oov_words=summary["oovWords"],
        g2p_words=summary["g2pWords"],
        warnings=summary["warnings"],
    )
    if dict(summary) != recomputed:
        raise ValueError("Manifest summary does not match frame data/canonical ordering")


def read_manifest(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"Manifest root must be an object: {path}")
    validate_manifest_object(payload)
    return payload


def verify_current_sources(payload: Mapping[str, Any], paths: CompilerPaths = CompilerPaths()) -> None:
    registry = load_registry()
    entry = registry.require_entry(str(payload["prID"]))
    descriptor = resolve_descriptor(entry.pr_id, paths)
    reconcile_descriptor(entry, descriptor)
    descriptor_path = paths.resources_root / str(payload["descriptorResourcePath"])
    audio_path = paths.resources_root / str(payload["audioResourcePath"])
    if descriptor_path.resolve() != descriptor.descriptor_path.resolve():
        raise ValueError("Manifest descriptorResourcePath no longer resolves to its registry descriptor")
    if audio_path.resolve() != (paths.audio_root / entry.audio_file).resolve():
        raise ValueError("Manifest audioResourcePath no longer resolves to its registry audio")
    if not descriptor_path.is_file() or sha256_file(descriptor_path) != payload["descriptorSHA256"]:
        raise ValueError("Manifest descriptor source is missing or stale")
    if not audio_path.is_file() or sha256_file(audio_path) != payload["audioSHA256"]:
        raise ValueError("Manifest audio source is missing or stale")
    from .transcript import normalize_transcript
    if sha256_bytes(normalize_transcript(descriptor.transcript).hash_text.encode("utf-8")) != payload["transcriptSHA256"]:
        raise ValueError("Manifest normalized transcript hash is stale")
    config = load_compiler_configuration()
    provenance = payload["analysisProvenance"]
    expected_files = {
        "toolchainLockSHA256": paths.toolchain_root / "toolchain.lock.json",
        "compilerConfigSHA256": paths.config_root / "compiler_config.json",
        "phonemePoseMapSHA256": paths.config_root / "phoneme_pose_map.json",
        "pronunciationOverridesSHA256": paths.config_root / "pronunciation_overrides.dict",
    }
    for key, source in expected_files.items():
        if not source.is_file() or sha256_file(source) != provenance[key]:
            raise ValueError(f"Manifest provenance is stale: {key}")
    if config.sha256 != provenance["compilerConfigSHA256"]:
        raise ValueError("Compiler configuration hash mismatch")
    manual_hash = provenance["manualOverrideSHA256"]
    manual_path = paths.config_root / "manual_overrides" / f"{entry.pr_id}.json"
    if manual_hash is None:
        if manual_path.exists():
            raise ValueError("A manual override now exists but manifest records null")
    elif not manual_path.is_file() or sha256_file(manual_path) != manual_hash:
        raise ValueError("Manual override source is missing or stale")


def validate_manifest_file(path: Path, *, verify_sources: bool = False) -> dict[str, Any]:
    payload = read_manifest(path)
    if verify_sources:
        verify_current_sources(payload)
    return payload


def validate_directory(
    directory: Path,
    *,
    verify_sources: bool = False,
    expected_count: int | None = None,
) -> ValidationResult:
    if not directory.is_dir():
        raise ValueError(f"Manifest directory does not exist: {directory}")
    temporary = [path for path in directory.rglob("*") if path.is_file() and path.name.startswith(".")]
    if temporary:
        raise ValueError(f"Temporary artifacts present: {[path.name for path in temporary]}")
    manifests = sorted(directory.glob("*.mouthframes.json"))
    if expected_count is not None and len(manifests) != expected_count:
        raise ValueError(f"Expected {expected_count} manifests, found {len(manifests)}")
    ids: list[str] = []
    for path in manifests:
        payload = validate_manifest_file(path, verify_sources=verify_sources)
        ids.append(str(payload["prID"]))
    if len(ids) != len(set(ids)):
        raise ValueError("Manifest directory contains duplicate PR IDs")
    if expected_count == 37:
        registry = load_registry()
        expected = {entry.pr_id for entry in registry.entries}
        actual = set(ids)
        if actual != expected:
            raise ValueError(
                f"Production completeness mismatch missing={sorted(expected-actual)} orphan={sorted(actual-expected)}"
            )
        if actual & registry.excluded_ids:
            raise ValueError("Production directory contains an excluded PR")
    return ValidationResult(len(manifests), tuple(ids))
