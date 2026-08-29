from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from typing import Any, Sequence

from .constants import (
    EVIDENCE_FALLBACK,
    EVIDENCE_MANUAL_OVERRIDE,
    POSE_TO_BIT,
    REQUIRED_POSES,
)
from .frame_expander import FrameDecision
from .timeline import AudioTimeline


@dataclass(frozen=True, slots=True)
class AnalysisProvenance:
    toolchain_lock_sha256: str
    compiler_config_sha256: str
    phoneme_pose_map_sha256: str
    pronunciation_overrides_sha256: str
    manual_override_sha256: str | None
    mfa: dict[str, Any]
    vad: dict[str, Any]


@dataclass(frozen=True, slots=True)
class AuthoredFrameManifest:
    schema_version: int
    compiler_version: str
    pr_id: str
    speaker_character_id: str
    interaction_surface: str
    descriptor_resource_path: str
    descriptor_sha256: str
    audio_resource_path: str
    audio_sha256: str
    transcript_sha256: str
    timeline: AudioTimeline
    provenance: AnalysisProvenance
    frames_sha256: str
    frames: tuple[FrameDecision, ...]
    summary: dict[str, Any]

    def provenance_to_dict(self) -> dict[str, Any]:
        mfa = self.provenance.mfa
        vad = self.provenance.vad
        return {
            "toolchainLockSHA256": self.provenance.toolchain_lock_sha256,
            "compilerConfigSHA256": self.provenance.compiler_config_sha256,
            "phonemePoseMapSHA256": self.provenance.phoneme_pose_map_sha256,
            "pronunciationOverridesSHA256": self.provenance.pronunciation_overrides_sha256,
            "manualOverrideSHA256": self.provenance.manual_override_sha256,
            "mfa": {
                "version": mfa["version"],
                "acousticModel": mfa["acousticModel"],
                "acousticModelVersion": mfa["acousticModelVersion"],
                "dictionary": mfa["dictionary"],
                "dictionaryVersion": mfa["dictionaryVersion"],
                "g2pModel": mfa["g2pModel"],
                "g2pModelVersion": mfa["g2pModelVersion"],
                "retryUsed": mfa["retryUsed"],
                "rawOutputSHA256": mfa["rawOutputSHA256"],
            },
            "vad": {
                "name": vad["name"],
                "version": vad["version"],
                "backend": vad["backend"],
                "modelSHA256": vad["modelSHA256"],
                "configurationSHA256": vad["configurationSHA256"],
            },
        }

    def to_ordered_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schema_version,
            "compilerVersion": self.compiler_version,
            "prID": self.pr_id,
            "speakerCharacterID": self.speaker_character_id,
            "interactionSurface": self.interaction_surface,
            "descriptorResourcePath": self.descriptor_resource_path,
            "descriptorSHA256": self.descriptor_sha256,
            "audioResourcePath": self.audio_resource_path,
            "audioSHA256": self.audio_sha256,
            "transcriptSHA256": self.transcript_sha256,
            "timeline": {
                "sampleRate": self.timeline.sample_rate,
                "sampleCount": self.timeline.sample_count,
                "durationSeconds": round(self.timeline.duration_seconds, 9),
                "framesPerSecond": self.timeline.frames_per_second,
                "samplesPerNominalFrame": self.timeline.samples_per_nominal_frame,
                "frameCount": self.timeline.frame_count,
            },
            "mouthLayerBits": {
                pose.value: POSE_TO_BIT[pose]
                for pose in REQUIRED_POSES
            },
            "requiredPoseFamilies": [pose.value for pose in REQUIRED_POSES],
            "analysisProvenance": self.provenance_to_dict(),
            "framesSHA256": self.frames_sha256,
            "frames": [
                {
                    "frameIndex": frame.frame_index,
                    "sampleStart": frame.sample_start,
                    "sampleEnd": frame.sample_end,
                    "pose": frame.pose.value,
                    "layerMask": frame.layer_mask,
                    "speechActive": frame.speech_active,
                    "phone": frame.source_phone,
                    "evidenceMask": frame.evidence_mask,
                }
                for frame in self.frames
            ],
            "summary": self.summary,
        }


def build_summary(
    frames: Sequence[FrameDecision],
    *,
    aligned_word_count: int,
    transcript_token_count: int,
    oov_words: Sequence[str] = (),
    g2p_words: Sequence[str] = (),
    warnings: Sequence[str] = (),
) -> dict[str, Any]:
    pose_counts = Counter(frame.pose.value for frame in frames)
    return {
        "poseFrameCounts": {
            pose.value: pose_counts.get(pose.value, 0)
            for pose in REQUIRED_POSES
        },
        "speechFrameCount": sum(frame.speech_active for frame in frames),
        "silenceFrameCount": sum(not frame.speech_active for frame in frames),
        "fallbackFrameCount": sum(
            bool(frame.evidence_mask & EVIDENCE_FALLBACK) for frame in frames
        ),
        "manualOverrideFrameCount": sum(
            bool(frame.evidence_mask & EVIDENCE_MANUAL_OVERRIDE) for frame in frames
        ),
        "alignedWordCount": aligned_word_count,
        "transcriptTokenCount": transcript_token_count,
        "oovWords": sorted(set(oov_words)),
        "g2pWords": sorted(set(g2p_words)),
        "warnings": sorted(set(warnings)),
    }
