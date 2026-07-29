#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from typing import NoReturn


def fail(message: str) -> NoReturn:
    raise SystemExit(f"ERROR: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def require_nonempty(path: Path, label: str) -> None:
    if not path.is_file() or path.stat().st_size <= 0:
        fail(f"Missing or empty {label}: {path}")


def load_json(path: Path, label: str) -> dict:
    require_nonempty(path, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Invalid {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def write_checksums(root: Path) -> None:
    entries = []
    for path in sorted(
        candidate
        for candidate in root.rglob("*")
        if candidate.is_file()
        and candidate.name != "checksums.sha256"
    ):
        entries.append(
            f"{sha256(path)}  {path.relative_to(root).as_posix()}"
        )
    (root / "checksums.sha256").write_text(
        "\n".join(entries) + "\n",
        encoding="utf-8",
    )


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(
        candidate
        for candidate in root.rglob("*")
        if candidate.is_file()
        and candidate.name != "checksums.sha256"
    ):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "little"))
        digest.update(relative)
        data = path.read_bytes()
        digest.update(len(data).to_bytes(8, "little"))
        digest.update(data)
    return digest.hexdigest()


def resolve_path(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def validate_audio(path: Path) -> None:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "stream=sample_rate,channels",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    streams = payload.get("streams") or []
    if len(streams) != 1:
        fail("Normalized reference must contain exactly one stream")
    stream = streams[0]
    if int(stream.get("sample_rate", 0)) != 24000:
        fail("Normalized reference sample rate must be 24000 Hz")
    if int(stream.get("channels", 0)) != 1:
        fail("Normalized reference must be mono")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--voice-id", required=True)
    parser.add_argument("--character-id", required=True)
    parser.add_argument("--variant-id", required=True)
    parser.add_argument("--registry", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    root = Path(args.root).resolve()
    profile = resolve_path(root, args.profile).resolve()
    registry_path = resolve_path(root, args.registry).resolve()
    variant_root = profile / "variants" / args.variant_id

    metadata = load_json(profile / "metadata.json", "metadata")
    variant = load_json(variant_root / "variant.json", "variant")
    manifest_path = (
        variant_root / "qwen_artifacts" / "clone_prompt_manifest.json"
    )
    manifest = load_json(manifest_path, "clone prompt manifest")

    expected_identity = {
        "voiceID": args.voice_id,
        "characterID": args.character_id,
    }
    for label, payload in (
        ("metadata", metadata),
        ("variant", variant),
        ("manifest", manifest),
    ):
        for key, expected in expected_identity.items():
            if payload.get(key) != expected:
                fail(f"{label} {key} mismatch")

    if metadata.get("defaultVariantID") != args.variant_id:
        fail("metadata defaultVariantID mismatch")
    if variant.get("variantID") != args.variant_id:
        fail("variant variantID mismatch")
    if manifest.get("variantID") != args.variant_id:
        fail("manifest variantID mismatch")
    if metadata.get("allowFallback") is not False:
        fail("metadata allowFallback must be false")
    if metadata.get("allowRuntimeRefAudioEncoding") is not False:
        fail("allowRuntimeRefAudioEncoding must be false")
    if metadata.get("allowPrerecordedDialoguePlayback") is not False:
        fail("allowPrerecordedDialoguePlayback must be false")
    if variant.get("allowFallback") is not False:
        fail("variant allowFallback must be false")
    if variant.get("allowPrerecordedDialoguePlayback") is not False:
        fail("variant allowPrerecordedDialoguePlayback must be false")

    reference = variant.get("reference") or {}
    ref_text = variant_root / reference.get("textPath", "")
    normalized_audio = (
        variant_root / reference.get("normalizedAudioPath", "")
    )
    original_audio = (
        variant_root / reference.get("originalAudioPath", "")
    )
    require_nonempty(ref_text, "reference transcript")
    require_nonempty(normalized_audio, "normalized reference")
    require_nonempty(original_audio, "original reference")
    validate_audio(normalized_audio)

    manifest_reference = manifest.get("reference") or {}
    normalized_text = ref_text.read_text(
        encoding="utf-8"
    ).strip()
    if sha256_bytes(
        normalized_text.encode("utf-8")
    ) != manifest_reference.get("textSHA256"):
        fail("Reference transcript does not match precomputed artifacts")
    if sha256(normalized_audio) != manifest_reference.get("audioSHA256"):
        fail("Normalized reference does not match precomputed artifacts")

    required_artifacts = [
        manifest_path,
        variant_root / "qwen_artifacts" / "clone_artifacts.safetensors",
        variant_root / "qwen_artifacts" / "reference_codes.i32le",
        variant_root / "qwen_artifacts" / "ref_text_tokens.i32le",
        variant_root / "qwen_artifacts" / "speaker_embedding.f32le",
    ]
    for path in required_artifacts:
        require_nonempty(path, "precomputed artifact")

    artifacts = variant.get("qwenArtifacts") or {}
    if artifacts.get("status") != "precomputed":
        fail("qwenArtifacts.status must be precomputed")
    if artifacts.get("manifestSHA256") != sha256(manifest_path):
        fail("variant manifestSHA256 mismatch")
    if artifacts.get("safetensorsSHA256") != sha256(
        variant_root / "qwen_artifacts" / "clone_artifacts.safetensors"
    ):
        fail("variant safetensorsSHA256 mismatch")

    write_checksums(variant_root)
    write_checksums(profile)
    revision = f"sha256:{tree_digest(profile)}"

    registry = load_json(registry_path, "voice registry")
    voices = registry.get("voices")
    if not isinstance(voices, list):
        fail("voice-registry voices must be an array")
    matches = [
        entry
        for entry in voices
        if entry.get("id") == args.voice_id
    ]
    if len(matches) != 1:
        fail(
            f"voice-registry must contain exactly one {args.voice_id} entry"
        )

    entry = matches[0]
    entry["revision"] = revision
    entry["defaultVariantID"] = args.variant_id
    entry["speakerID"] = args.character_id
    entry["characterID"] = args.character_id
    entry["voiceID"] = args.voice_id
    entry["allowFallback"] = False

    registry_path.write_text(
        json.dumps(registry, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(revision)


if __name__ == "__main__":
    main()
