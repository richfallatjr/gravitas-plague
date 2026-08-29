from __future__ import annotations

import hashlib
from pathlib import Path

from mind_eye_lipsync.constants import EVIDENCE_MFA, EVIDENCE_VAD_SILENCE, EVIDENCE_VAD_SPEECH, MouthPose, POSE_TO_BIT
from mind_eye_lipsync.deterministic_json import write_atomic_json
from mind_eye_lipsync.frame_expander import FrameDecision, frames_sha256
from mind_eye_lipsync.manifest import AnalysisProvenance, AuthoredFrameManifest, build_summary
from mind_eye_lipsync.registry import load_registry
from mind_eye_lipsync.set_index import build_index_payload
from mind_eye_lipsync.timeline import timeline_for_sample_count
from mind_eye_lipsync.hashing import sha256_file


HASH = "0" * 64


def _hash(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def write_complete_set(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    poses = (MouthPose.REST, MouthPose.SMALL, MouthPose.WIDE, MouthPose.ROUND, MouthPose.TEETH)
    for entry in load_registry().entries:
        timeline = timeline_for_sample_count(4_000)
        frames = tuple(
            FrameDecision(
                index,
                index * 800,
                (index + 1) * 800,
                pose,
                POSE_TO_BIT[pose],
                pose is not MouthPose.REST,
                "sil" if pose is MouthPose.REST else "AA1",
                EVIDENCE_MFA | (EVIDENCE_VAD_SILENCE if pose is MouthPose.REST else EVIDENCE_VAD_SPEECH),
            )
            for index, pose in enumerate(poses)
        )
        payload = AuthoredFrameManifest(
            schema_version=1,
            compiler_version="mind-eye-authored-frame-compiler/1.0.3",
            pr_id=entry.pr_id,
            speaker_character_id=entry.speaker_character_id,
            interaction_surface=entry.interaction_surface,
            descriptor_resource_path=f"Turing/Prerecordings/{entry.pr_id}.json",
            descriptor_sha256=_hash(f"descriptor:{entry.pr_id}"),
            audio_resource_path=f"Turing/Audio/prerecordings/{entry.audio_file}",
            audio_sha256=_hash(f"audio:{entry.pr_id}"),
            transcript_sha256=_hash(f"transcript:{entry.pr_id}"),
            timeline=timeline,
            provenance=AnalysisProvenance(
                HASH, HASH, HASH, HASH, None,
                {"version":"3.3.9","acousticModel":"english_us_arpa","acousticModelVersion":"3.0.0","dictionary":"english_us_arpa","dictionaryVersion":"3.0.0","g2pModel":"english_us_arpa","g2pModelVersion":"2.0.0a","retryUsed":False,"rawOutputSHA256":_hash(f"mfa:{entry.pr_id}")},
                {"name":"silero-vad","version":"6.2.1","backend":"onnx","modelSHA256":HASH,"configurationSHA256":HASH},
            ),
            frames_sha256=frames_sha256(frames),
            frames=frames,
            summary=build_summary(frames, aligned_word_count=1, transcript_token_count=1),
        ).to_ordered_dict()
        path = root / f"{entry.pr_id}.mouthframes.json"
        write_atomic_json(path, payload)
    index = build_index_payload(root, verify_sources=False)
    write_atomic_json(root / "index.json", index)
    return root


def write_reports(manifest_root: Path, report_root: Path) -> Path:
    report_root.mkdir(parents=True, exist_ok=True)
    for manifest_path in manifest_root.glob("*.mouthframes.json"):
        import json
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        write_atomic_json(report_root / f"{payload['prID']}.report.json", {
            "schemaVersion": 1,
            "prID": payload["prID"],
            "manifestSHA256": sha256_file(manifest_path),
            "vadSpeechPercent": 80.0,
            "decoderParity": {"ffmpegSampleCount":4000,"appleSampleCount":3999,"signedDifference":-1,"warning":None},
        })
        (report_root / f"{payload['prID']}.report.svg").write_text("<svg xmlns='http://www.w3.org/2000/svg'></svg>\n", encoding="utf-8")
    return report_root
