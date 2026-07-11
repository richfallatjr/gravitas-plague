#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

VOICE_ID = "rich_base_clone_v1"
CHARACTER_ID = "rich"
VARIANT_ID = "rich_reference_01"

def fail(message: str) -> "NoReturn":
    raise SystemExit(f"ERROR: {message}")

def require_nonempty(path: Path, label: str) -> None:
    if not path.is_file() or path.stat().st_size <= 0:
        fail(f"Missing or empty {label}: {path}")

def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "little"))
        digest.update(relative)
        data = path.read_bytes()
        digest.update(len(data).to_bytes(8, "little"))
        digest.update(data)
    return digest.hexdigest()

def main() -> None:
    if len(sys.argv) != 2:
        fail("Usage: finalize_rich_voice_registry.py <gravitas-root>")

    repo = Path(sys.argv[1]).resolve()
    resource_root = repo / "Gravitas Plague" / "TuringResources" / "Turing"
    profile = (
        resource_root
        / "Voices"
        / "Cloned"
        / "Rich"
        / "BaseClone"
        / f"{VOICE_ID}.qwenclone"
    )
    registry_path = resource_root / "Config" / "voice-registry.json"

    metadata_path = profile / "metadata.json"
    variant_root = profile / "variants" / VARIANT_ID
    variant_path = variant_root / "variant.json"

    require_nonempty(metadata_path, "Rich metadata")
    require_nonempty(variant_path, "Rich variant")
    require_nonempty(
        variant_root / "ref_audio" / "original" / "rich-clone-ref-fast.mp3",
        "Rich original reference",
    )
    require_nonempty(
        variant_root / "ref_audio" / "normalized" / "ref_24000_mono.wav",
        "Rich normalized reference",
    )
    require_nonempty(variant_root / "ref_text.txt", "Rich reference transcript")

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    variant = json.loads(variant_path.read_text(encoding="utf-8"))

    if metadata.get("voiceID") != VOICE_ID:
        fail("metadata voiceID mismatch")
    if metadata.get("characterID") != CHARACTER_ID:
        fail("metadata characterID mismatch")
    if metadata.get("defaultVariantID") != VARIANT_ID:
        fail("metadata defaultVariantID mismatch")
    if metadata.get("allowFallback") is not False:
        fail("Rich metadata allowFallback must be false")
    if metadata.get("allowRuntimeRefAudioEncoding") is not False:
        fail("Rich metadata allowRuntimeRefAudioEncoding must be false")
    if metadata.get("allowPrerecordedDialoguePlayback") is not False:
        fail("Rich metadata allowPrerecordedDialoguePlayback must be false")

    if variant.get("voiceID") != VOICE_ID:
        fail("variant voiceID mismatch")
    if variant.get("characterID") != CHARACTER_ID:
        fail("variant characterID mismatch")
    if variant.get("variantID") != VARIANT_ID:
        fail("variant variantID mismatch")
    if variant.get("allowFallback") is not False:
        fail("Rich variant allowFallback must be false")
    if variant.get("allowPrerecordedDialoguePlayback") is not False:
        fail("Rich variant allowPrerecordedDialoguePlayback must be false")

    artifacts = variant.get("qwenArtifacts") or {}
    if artifacts.get("status") not in {"precomputed", "ready"}:
        fail("Rich qwenArtifacts.status is not precomputed/ready")

    required_artifacts = [
        variant_root / "qwen_artifacts" / "clone_prompt_manifest.json",
        variant_root / "qwen_artifacts" / "reference_codes.i32le",
        variant_root / "qwen_artifacts" / "ref_text_tokens.i32le",
        variant_root / "qwen_artifacts" / "speaker_embedding.f32le",
    ]
    for path in required_artifacts:
        require_nonempty(path, "Rich precomputed artifact")

    if not registry_path.is_file():
        fail(f"Missing voice registry: {registry_path}")

    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    voices = registry.get("voices")
    if not isinstance(voices, list):
        fail("voice-registry voices must be an array")

    matches = [voice for voice in voices if voice.get("id") == VOICE_ID]
    if len(matches) != 1:
        fail(f"voice-registry must contain exactly one {VOICE_ID} entry")

    revision = f"sha256:{tree_digest(profile)}"
    entry = matches[0]
    entry["revision"] = revision
    entry["defaultVariantID"] = VARIANT_ID
    entry["speakerID"] = CHARACTER_ID
    entry["characterID"] = CHARACTER_ID
    entry["voiceID"] = VOICE_ID
    entry["allowFallback"] = False

    if registry.get("activeDefaultVoiceID") != "big_mike_base_clone_v1":
        fail("Do not change activeDefaultVoiceID from Big Mike")
    if registry.get("activeVoiceID") != "big_mike_base_clone_v1":
        fail("Do not change activeVoiceID from Big Mike")

    registry_path.write_text(
        json.dumps(registry, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(revision)

if __name__ == "__main__":
    main()
