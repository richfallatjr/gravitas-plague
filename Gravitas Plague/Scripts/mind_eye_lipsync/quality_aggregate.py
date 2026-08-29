from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any

from .errors import Diagnostic
from .hashing import sha256_file
from .set_index import POSE_ORDER, SPEAKER_ORDER
from .validator import validate_manifest_file


@dataclass(frozen=True, slots=True)
class ManifestQualityRecord:
    pr_id: str
    speaker_character_id: str
    interaction_surface: str
    duration_seconds: float
    frame_count: int
    pose_frame_counts: dict[str, int]
    speech_frame_count: int
    fallback_frame_count: int
    manual_override_frame_count: int
    warning_codes: tuple[str, ...]
    longest_same_pose_run_frames: int
    trailing_nonrest_frames: int
    leading_nonrest_frames: int
    mfa_retry_used: bool
    g2p_words: tuple[str, ...]
    decoder_parity_difference: int
    manifest_bytes: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "prID": self.pr_id,
            "speakerCharacterID": self.speaker_character_id,
            "interactionSurface": self.interaction_surface,
            "durationSeconds": self.duration_seconds,
            "frameCount": self.frame_count,
            "poseFrameCounts": self.pose_frame_counts,
            "speechFrameCount": self.speech_frame_count,
            "fallbackFrameCount": self.fallback_frame_count,
            "manualOverrideFrameCount": self.manual_override_frame_count,
            "warningCodes": list(self.warning_codes),
            "longestSamePoseRunFrames": self.longest_same_pose_run_frames,
            "trailingNonrestFrames": self.trailing_nonrest_frames,
            "leadingNonrestFrames": self.leading_nonrest_frames,
            "mfaRetryUsed": self.mfa_retry_used,
            "g2pWords": list(self.g2p_words),
            "decoderParityDifference": self.decoder_parity_difference,
            "manifestBytes": self.manifest_bytes,
            "bytesPerFrame": round(self.manifest_bytes / max(1, self.frame_count), 6),
        }


@dataclass(frozen=True, slots=True)
class ProductionQualitySummary:
    records: tuple[ManifestQualityRecord, ...]
    aggregate_pose_frame_counts: dict[str, int]
    warning_counts: dict[str, int]
    total_fallback_frames: int
    total_override_frames: int
    diagnostics: tuple[Diagnostic, ...]

    @property
    def hard_failure_count(self) -> int:
        return sum(item.severity == "error" for item in self.diagnostics)

    @property
    def is_valid(self) -> bool:
        return len(self.records) == 37 and self.hard_failure_count == 0

    def to_dict(self) -> dict[str, Any]:
        ordered = sorted(self.records, key=lambda item: item.pr_id)
        largest = max(ordered, key=lambda item: item.manifest_bytes)
        smallest = min(ordered, key=lambda item: item.manifest_bytes)
        return {
            "status": "PASS" if self.is_valid else "FAIL",
            "valid": self.is_valid,
            "hardFailureCount": self.hard_failure_count,
            "records": [item.to_dict() for item in ordered],
            "aggregatePoseFrameCounts": self.aggregate_pose_frame_counts,
            "warningCounts": self.warning_counts,
            "totalFallbackFrames": self.total_fallback_frames,
            "totalOverrideFrames": self.total_override_frames,
            "warningBearingPRCount": sum(bool(item.warning_codes) for item in ordered),
            "fallbackBearingPRCount": sum(item.fallback_frame_count > 0 for item in ordered),
            "overrideBearingPRCount": sum(item.manual_override_frame_count > 0 for item in ordered),
            "mfaRetryPRCount": sum(item.mfa_retry_used for item in ordered),
            "g2pPRCount": sum(bool(item.g2p_words) for item in ordered),
            "decoderParityWarningCount": sum(abs(item.decoder_parity_difference) > 48 for item in ordered),
            "largestManifest": {"prID": largest.pr_id, "bytes": largest.manifest_bytes},
            "smallestManifest": {"prID": smallest.pr_id, "bytes": smallest.manifest_bytes},
            "diagnostics": [
                {
                    "code": item.code,
                    "message": item.message,
                    "severity": item.severity,
                    "prID": item.pr_id,
                    "path": item.path,
                }
                for item in sorted(self.diagnostics, key=lambda value: (value.severity, value.code, value.pr_id or ""))
            ],
        }


def _diag(code: str, message: str, pr_id: str, severity: str = "warning") -> Diagnostic:
    return Diagnostic(code=code, message=message, severity=severity, pr_id=pr_id)


def _run_lengths(frames: list[dict[str, Any]]) -> tuple[int, int, int]:
    longest = 0
    current = 0
    previous: str | None = None
    for frame in frames:
        pose = str(frame["pose"])
        current = current + 1 if pose == previous else 1
        longest = max(longest, current)
        previous = pose
    leading = 0
    for frame in frames:
        if frame["pose"] == "rest":
            break
        leading += 1
    trailing = 0
    for frame in reversed(frames):
        if frame["pose"] == "rest":
            break
        trailing += 1
    return longest, leading, trailing


def analyze_quality(
    manifest_directory: Path,
    report_directory: Path,
    *,
    verify_sources: bool = True,
) -> ProductionQualitySummary:
    manifest_paths = sorted(manifest_directory.glob("*.mouthframes.json"))
    records: list[ManifestQualityRecord] = []
    diagnostics: list[Diagnostic] = []
    speaker_nonrest = Counter()
    warning_counts = Counter()
    for manifest_path in manifest_paths:
        manifest = validate_manifest_file(manifest_path, verify_sources=verify_sources)
        pr_id = str(manifest["prID"])
        report_path = report_directory / f"{pr_id}.report.json"
        if not report_path.is_file():
            diagnostics.append(_diag("missingReport", "The production report is missing", pr_id, "error"))
            continue
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
        except Exception as error:
            diagnostics.append(_diag("malformedReport", str(error), pr_id, "error"))
            continue
        manifest_hash = sha256_file(manifest_path)
        if report.get("prID") != pr_id or report.get("manifestSHA256") != manifest_hash:
            diagnostics.append(_diag("reportManifestMismatch", "Report PR ID/hash does not match manifest", pr_id, "error"))
        parity = report.get("decoderParity")
        if not isinstance(parity, dict) or not isinstance(parity.get("signedDifference"), int):
            diagnostics.append(_diag("decoderParityMissing", "Report lacks decoder parity evidence", pr_id, "error"))
            parity_difference = 0
        else:
            parity_difference = int(parity["signedDifference"])
            if abs(parity_difference) > 400:
                diagnostics.append(_diag("decoderParityFailure", "Decoder parity exceeds 400 samples", pr_id, "error"))

        frames = manifest["frames"]
        summary = manifest["summary"]
        pose_counts = {pose: int(summary["poseFrameCounts"][pose]) for pose in POSE_ORDER}
        nonrest = len(frames) - pose_counts["rest"]
        speech = int(summary["speechFrameCount"])
        fallback = int(summary["fallbackFrameCount"])
        overrides = int(summary["manualOverrideFrameCount"])
        warnings = tuple(sorted(str(value) for value in summary["warnings"]))
        longest, leading, trailing = _run_lengths(frames)
        if not frames:
            diagnostics.append(_diag("zeroFrames", "Manifest contains zero frames", pr_id, "error"))
        if speech <= 0:
            diagnostics.append(_diag("zeroSpeechFrames", "Manifest contains zero speech frames", pr_id, "error"))
        if nonrest <= 0:
            diagnostics.append(_diag("zeroNonrestFrames", "Manifest contains zero non-rest frames", pr_id, "error"))
        if fallback / max(1, len(frames)) > 0.25:
            diagnostics.append(_diag("fallbackRatioFailure", "Fallback frames exceed 25%", pr_id, "error"))
        if fallback:
            diagnostics.append(_diag("fallbackFrames", f"{fallback} fallback frames require review", pr_id))
        if overrides:
            diagnostics.append(_diag("manualOverrideFrames", f"{overrides} manual-override frames require review", pr_id))
        rest_ratio = pose_counts["rest"] / max(1, len(frames))
        if rest_ratio < 0.01 or rest_ratio > 0.80:
            diagnostics.append(_diag("restCoverage", f"Rest coverage is {rest_ratio:.2%}", pr_id))
        if speech:
            dominant = max(pose_counts[pose] for pose in POSE_ORDER if pose != "rest")
            if dominant / speech > 0.95:
                diagnostics.append(_diag("dominantSpeechPose", "One non-rest pose exceeds 95% of speech frames", pr_id))
        if manifest["analysisProvenance"]["mfa"]["retryUsed"]:
            diagnostics.append(_diag("mfaRetryUsed", "MFA deterministic retry was used", pr_id))
        if summary["g2pWords"]:
            diagnostics.append(_diag("g2pWords", f"G2P words: {summary['g2pWords']}", pr_id))
        if trailing > 12:
            diagnostics.append(_diag("trailingNonrest", f"Trailing non-rest run is {trailing} frames", pr_id))
        if leading > 12:
            diagnostics.append(_diag("leadingNonrest", f"Leading non-rest run is {leading} frames", pr_id))
        if longest > 120:
            diagnostics.append(_diag("longSamePoseRun", f"Longest same-pose run is {longest} frames", pr_id))
        speech_ratio = speech / max(1, len(frames))
        if speech_ratio < 0.05 or speech_ratio > 0.95:
            diagnostics.append(_diag("vadSpeechRatio", f"VAD speech coverage is {speech_ratio:.2%}", pr_id))
        if abs(parity_difference) > 48:
            diagnostics.append(_diag("decoderParityWarning", f"Decoder parity differs by {parity_difference} samples", pr_id))
        for warning in warnings:
            warning_counts[warning.split(":", 1)[0]] += 1
        speaker_nonrest[str(manifest["speakerCharacterID"])] += nonrest
        records.append(ManifestQualityRecord(
            pr_id=pr_id,
            speaker_character_id=str(manifest["speakerCharacterID"]),
            interaction_surface=str(manifest["interactionSurface"]),
            duration_seconds=float(manifest["timeline"]["durationSeconds"]),
            frame_count=len(frames),
            pose_frame_counts=pose_counts,
            speech_frame_count=speech,
            fallback_frame_count=fallback,
            manual_override_frame_count=overrides,
            warning_codes=warnings,
            longest_same_pose_run_frames=longest,
            trailing_nonrest_frames=trailing,
            leading_nonrest_frames=leading,
            mfa_retry_used=bool(manifest["analysisProvenance"]["mfa"]["retryUsed"]),
            g2p_words=tuple(summary["g2pWords"]),
            decoder_parity_difference=parity_difference,
            manifest_bytes=manifest_path.stat().st_size,
        ))

    aggregate = {
        pose: sum(record.pose_frame_counts[pose] for record in records)
        for pose in POSE_ORDER
    }
    if len(records) != 37:
        diagnostics.append(Diagnostic("productionCount", f"Expected 37 quality records, found {len(records)}", "error"))
    for pose, count in aggregate.items():
        if count <= 0:
            diagnostics.append(Diagnostic("aggregatePoseMissing", f"Aggregate pose {pose} has zero frames", "error"))
    for speaker in SPEAKER_ORDER:
        if speaker_nonrest[speaker] <= 0:
            diagnostics.append(Diagnostic("speakerNonrestMissing", f"Speaker {speaker} has zero non-rest frames", "error"))
    return ProductionQualitySummary(
        records=tuple(sorted(records, key=lambda item: item.pr_id)),
        aggregate_pose_frame_counts=aggregate,
        warning_counts={key: warning_counts[key] for key in sorted(warning_counts)},
        total_fallback_frames=sum(item.fallback_frame_count for item in records),
        total_override_frames=sum(item.manual_override_frame_count for item in records),
        diagnostics=tuple(diagnostics),
    )
