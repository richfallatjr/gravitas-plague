from __future__ import annotations

from pathlib import Path

import pytest

from mind_eye_lipsync.constants import EVIDENCE_MFA, EVIDENCE_VAD_SILENCE, MouthPose
from mind_eye_lipsync.deterministic_json import canonical_json_bytes
from mind_eye_lipsync.frame_expander import FrameDecision, frames_sha256
from mind_eye_lipsync.manifest import AnalysisProvenance, AuthoredFrameManifest, build_summary
from mind_eye_lipsync.timeline import timeline_for_sample_count
from mind_eye_lipsync.validator import validate_manifest_object


HASH = "0" * 64


def make_payload() -> dict:
    timeline = timeline_for_sample_count(800)
    frames = (FrameDecision(0, 0, 800, MouthPose.REST, 1, False, "sil", EVIDENCE_MFA | EVIDENCE_VAD_SILENCE),)
    manifest = AuthoredFrameManifest(
        schema_version=1,
        compiler_version="mind-eye-authored-frame-compiler/1.0.3",
        pr_id="prologue.walkie.bigMike.richContact.001",
        speaker_character_id="big_mike",
        interaction_surface="walkie",
        descriptor_resource_path="Turing/Prerecordings/prologue.walkie.bigMike.richContact.001.json",
        descriptor_sha256=HASH,
        audio_resource_path="Turing/Audio/prerecordings/pr-big-mike-rich-contact.mp3",
        audio_sha256=HASH,
        transcript_sha256=HASH,
        timeline=timeline,
        provenance=AnalysisProvenance(
            HASH, HASH, HASH, HASH, None,
            {"version":"3.3.9","acousticModel":"english_us_arpa","acousticModelVersion":"3.0.0","dictionary":"english_us_arpa","dictionaryVersion":"3.0.0","g2pModel":"english_us_arpa","g2pModelVersion":"2.0.0a","retryUsed":False,"rawOutputSHA256":HASH},
            {"name":"silero-vad","version":"6.2.1","backend":"onnx","modelSHA256":HASH,"configurationSHA256":HASH},
        ),
        frames_sha256=frames_sha256(frames),
        frames=frames,
        summary=build_summary(frames, aligned_word_count=1, transcript_token_count=1),
    )
    return manifest.to_ordered_dict()


def test_manifest_order_bytes_roundtrip_and_semantics() -> None:
    payload = make_payload()
    assert list(payload)[:5] == ["schemaVersion", "compilerVersion", "prID", "speakerCharacterID", "interactionSurface"]
    assert canonical_json_bytes(payload) == canonical_json_bytes(payload)
    assert canonical_json_bytes(payload).endswith(b"\n")
    validate_manifest_object(payload)


def test_additional_or_discontinuous_frame_rejected() -> None:
    payload = make_payload()
    payload["extra"] = True
    with pytest.raises(ValueError):
        validate_manifest_object(payload)
    payload = make_payload()
    payload["frames"][0]["sampleStart"] = 1
    with pytest.raises(ValueError):
        validate_manifest_object(payload)


def test_schema_is_strict_at_every_object() -> None:
    import json
    schema = json.loads((Path(__file__).resolve().parents[2] / "mind_eye_lipsync/schemas/authored_frame_manifest.schema.json").read_text())
    objects = []
    def visit(value):
        if isinstance(value, dict):
            if value.get("type") == "object":
                objects.append(value)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(schema)
    assert objects and all(value.get("additionalProperties") is False for value in objects)


@pytest.mark.parametrize(("field", "value"), [
    ("durationSeconds", float("nan")),
    ("frameCount", True),
])
def test_nonfinite_or_boolean_timeline_number_is_rejected(field: str, value: object) -> None:
    payload = make_payload()
    payload["timeline"][field] = value
    with pytest.raises(ValueError):
        validate_manifest_object(payload)


def test_absolute_resource_path_and_unpinned_provenance_are_rejected() -> None:
    payload = make_payload()
    payload["audioResourcePath"] = "/tmp/audio.mp3"
    with pytest.raises(ValueError):
        validate_manifest_object(payload)
    payload = make_payload()
    payload["analysisProvenance"]["mfa"]["version"] = "3.4.0"
    with pytest.raises(ValueError):
        validate_manifest_object(payload)
