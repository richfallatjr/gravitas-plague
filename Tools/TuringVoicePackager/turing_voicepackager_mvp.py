#!/usr/bin/env python3
"""
Turing Voice Packager MVP

Mac-only authoring utility. Not for the visionOS app target.

Packages an ElevenLabs Big Mike reference clip + exact transcript into a
.qwenclone profile that Turing can load for Base clone runtime work.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, NoReturn, Optional, Tuple

IGNORED_DIR_NAMES = {
    ".git",
    ".build",
    "build",
    "DerivedData",
    "TuringRecoveryArtifacts",
    "TuringRollbackArtifacts",
    "node_modules",
    ".swiftpm",
}

AUDIO_EXTENSIONS = {".mp3", ".wav", ".m4a", ".aiff", ".aif", ".caf"}


def log(message: str, **fields: Any) -> None:
    print(f"[TuringVoicePackager] {message}")
    for key, value in fields.items():
        print(f"  {key}: {value}")


def fail(message: str) -> NoReturn:
    print(f"[TuringVoicePackager] failed\n  error: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"JSON file not found: {path}")
    except json.JSONDecodeError as exc:
        fail(f"Invalid JSON in {path}: {exc}")


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=False) + "\n"
    path.write_text(data, encoding="utf-8")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def repo_relative(root: Path, path: Path) -> str:
    try:
        return str(path.relative_to(root)).replace(os.sep, "/")
    except ValueError:
        return str(path)


def find_file_by_name(root: Path, filename: str) -> Optional[Path]:
    direct = root / filename
    if direct.exists():
        return direct

    matches: List[Path] = []
    for current_root, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in IGNORED_DIR_NAMES]
        if filename in files:
            matches.append(Path(current_root) / filename)

    if not matches:
        return None

    # Prefer authoring/resources locations over arbitrary build output.
    def score(p: Path) -> Tuple[int, int, str]:
        s = str(p).lower()
        preferred = 0
        if "authoring" in s:
            preferred -= 30
        if "turingresources" in s or "/turing/" in s:
            preferred -= 20
        if "bigmike" in s or "big-mike" in s:
            preferred -= 10
        return (preferred, len(str(p)), str(p))

    matches.sort(key=score)
    return matches[0]


def resolve_audio_path(root: Path, raw_path: Optional[str], filename_hint: Optional[str]) -> Path:
    if raw_path:
        candidate = Path(raw_path).expanduser()
        if candidate.is_absolute() and candidate.exists():
            return candidate
        relative = root / candidate
        if relative.exists():
            return relative
        if candidate.name:
            found = find_file_by_name(root, candidate.name)
            if found:
                return found
    if filename_hint:
        found = find_file_by_name(root, filename_hint)
        if found:
            return found
    fail(f"Could not find source audio. raw_path={raw_path!r}, filename_hint={filename_hint!r}")


def run_afconvert(source: Path, output: Path, require: bool) -> bool:
    afconvert = shutil.which("afconvert")
    if afconvert is None:
        if require:
            fail("afconvert not found. Run on macOS with Xcode command-line tools, or pass --skip-normalize for inspection only.")
        return False

    output.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        afconvert,
        str(source),
        str(output),
        "-f",
        "WAVE",
        "-d",
        "LEF32@24000",
        "-c",
        "1",
    ]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown afconvert error").strip()
        if require:
            fail(f"afconvert failed for {source}: {detail}")
        print(f"[TuringVoicePackager] warning: afconvert failed; normalized WAV skipped\n  error: {detail}")
        return False
    if not output.exists() or output.stat().st_size <= 44:
        if require:
            fail(f"afconvert did not create a valid WAV: {output}")
        return False
    return True


def write_checksums(path: Path, entries: Iterable[Tuple[str, str]]) -> None:
    lines = [f"{digest}  {rel}" for rel, digest in sorted(entries, key=lambda item: item[0])]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def profile_revision(profile_root: Path) -> str:
    h = hashlib.sha256()
    for path in sorted(p for p in profile_root.rglob("*") if p.is_file() and p.name != "checksums.sha256"):
        rel = str(path.relative_to(profile_root)).replace(os.sep, "/")
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(path.read_bytes())
        h.update(b"\0")
    return h.hexdigest()


def build_selection_catalog(manifest: Dict[str, Any], variants: List[Dict[str, Any]]) -> Dict[str, Any]:
    catalog_variants: List[Dict[str, Any]] = []
    for variant in variants:
        perf = variant.get("performance", {})
        catalog_variants.append(
            {
                "variantID": variant["variantID"],
                "description": perf.get(
                    "selectionHint",
                    f"Big Mike {variant['variantID']} performance variant.",
                ),
                "tags": perf.get("tags", []),
                "intensity": perf.get("intensity"),
                "pace": perf.get("pace"),
                "energy": perf.get("energy"),
                "allowedContexts": perf.get("allowedContexts", []),
                "blockedContexts": perf.get("blockedContexts", []),
            }
        )
    return {
        "schemaVersion": 1,
        "voiceID": manifest["voiceID"],
        "characterID": manifest["characterID"],
        "defaultVariantID": manifest.get("defaultVariantID", variants[0]["variantID"]),
        "variants": catalog_variants,
    }


def update_voice_registry(
    root: Path,
    registry_path: Path,
    profile_root: Path,
    manifest: Dict[str, Any],
    revision: str,
) -> None:
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    if registry_path.exists():
        backup_path = registry_path.with_suffix(registry_path.suffix + ".bak")
        shutil.copy2(registry_path, backup_path)
        payload = load_json(registry_path)
    else:
        payload = {"schemaVersion": 1, "voices": []}

    entry = {
        "id": manifest["voiceID"],
        "voiceID": manifest["voiceID"],
        "characterID": manifest["characterID"],
        "speakerID": manifest["characterID"],
        "displayName": manifest.get("displayName", manifest["voiceID"]),
        "enabled": True,
        "kind": "baseCloneProfile",
        "profileKind": "qwenBaseCloneReferenceProfile",
        "runtimeMode": "baseClone",
        "language": manifest.get("language", "english"),
        "modelID": manifest.get("modelID", "qwen3-tts-12hz-1.7b-base-4bit"),
        "resourcePath": repo_relative(root / "Gravitas Plague" / "TuringResources", profile_root),
        "profilePath": repo_relative(root / "Gravitas Plague" / "TuringResources", profile_root),
        "revision": f"sha256:{revision}",
        "defaultVariantID": manifest.get("defaultVariantID", "broadcast_reading_lazy"),
        "selectionCatalogPath": "selection-catalog.json",
        "allowFallback": False,
    }

    if isinstance(payload.get("voices"), list):
        voices = payload["voices"]
        replaced = False
        for index, existing in enumerate(voices):
            if isinstance(existing, dict) and existing.get("id") == entry["id"]:
                voices[index] = {**existing, **entry}
                replaced = True
                break
        if not replaced:
            voices.append(entry)
    elif isinstance(payload.get("voices"), dict):
        payload["voices"][entry["id"]] = entry
    else:
        payload["voices"] = [entry]

    write_json(registry_path, payload)
    log("voice registry updated", id=entry["id"], path=registry_path)


def package_manifest(args: argparse.Namespace) -> Path:
    root = Path(args.root).expanduser().resolve()
    manifest_path = Path(args.manifest).expanduser()
    if not manifest_path.is_absolute():
        manifest_path = root / manifest_path
    manifest = load_json(manifest_path)

    if manifest.get("schemaVersion") != 1:
        fail("Manifest schemaVersion must be 1")

    variants = manifest.get("variants")
    if not isinstance(variants, list) or not variants:
        fail("Manifest must include a non-empty variants array")

    log(
        "loaded manifest",
        voiceID=manifest.get("voiceID"),
        variants=len(variants),
        manifest=manifest_path,
    )

    profile_out = Path(args.profile_out or manifest.get("profileOutputPath") or "")
    if not str(profile_out):
        fail("profileOutputPath missing from manifest and --profile-out not supplied")
    if not profile_out.is_absolute():
        profile_root = root / profile_out
    else:
        profile_root = profile_out

    if args.clean and profile_root.exists():
        shutil.rmtree(profile_root)

    profile_root.mkdir(parents=True, exist_ok=True)

    variant_refs: List[Dict[str, str]] = []
    profile_checksum_entries: List[Tuple[str, str]] = []

    for variant in variants:
        variant_id = variant.get("variantID")
        if not variant_id or not isinstance(variant_id, str):
            fail("Every variant must include string variantID")
        transcript = variant.get("transcript")
        if not transcript or not isinstance(transcript, str) or not transcript.strip():
            fail(f"Variant {variant_id} transcript is empty")

        audio_source = resolve_audio_path(
            root,
            args.audio or variant.get("sourceAudioPath"),
            manifest.get("sourceAudioFilename"),
        )
        if audio_source.suffix.lower() not in AUDIO_EXTENSIONS:
            fail(f"Unsupported audio extension for {audio_source}")
        if audio_source.stat().st_size <= 0:
            fail(f"Source audio is empty: {audio_source}")

        log("source audio found", variantID=variant_id, file=audio_source)

        variant_root = profile_root / "variants" / variant_id
        original_dir = variant_root / "ref_audio" / "original"
        normalized_dir = variant_root / "ref_audio" / "normalized"
        original_dir.mkdir(parents=True, exist_ok=True)
        normalized_dir.mkdir(parents=True, exist_ok=True)

        original_audio_dest = original_dir / audio_source.name
        shutil.copy2(audio_source, original_audio_dest)

        normalized_audio_dest = normalized_dir / "ref_24000_mono.wav"
        normalized = False
        if not args.skip_normalize:
            normalized = run_afconvert(original_audio_dest, normalized_audio_dest, require=True)
            log(
                "normalized reference audio",
                variantID=variant_id,
                sampleRate=24000,
                channels=1,
                output=normalized_audio_dest,
            )

        text_path = variant_root / "ref_text.txt"
        text_path.write_text(transcript.strip() + "\n", encoding="utf-8")

        performance = variant.get("performance", {})
        variant_json = {
            "schemaVersion": 1,
            "variantID": variant_id,
            "displayName": variant.get("displayName", variant_id),
            "voiceID": manifest["voiceID"],
            "characterID": manifest["characterID"],
            "kind": "baseCloneReferenceVariant",
            "language": manifest.get("language", "english"),
            "sourceProvider": manifest.get("sourceProvider", "elevenlabs"),
            "performance": performance,
            "reference": {
                "originalAudioPath": f"ref_audio/original/{original_audio_dest.name}",
                "normalizedAudioPath": "ref_audio/normalized/ref_24000_mono.wav" if normalized else None,
                "textPath": "ref_text.txt",
                "sampleRate": 24000 if normalized else None,
                "channels": 1 if normalized else None,
                "normalizedFormat": "wav_float32_le" if normalized else None,
                "originalAudioSHA256": sha256_file(original_audio_dest),
                "normalizedAudioSHA256": sha256_file(normalized_audio_dest) if normalized else None,
                "textSHA256": sha256_text(transcript.strip() + "\n"),
            },
            "qwenArtifacts": {
                "status": "notPrecomputed",
                "speakerEmbeddingPath": None,
                "referenceCodesPath": None,
                "referenceTextTokensPath": None,
                "clonePromptManifestPath": None,
            },
            "allowFallback": False,
            "allowPrerecordedDialoguePlayback": False,
        }
        write_json(variant_root / "variant.json", variant_json)

        variant_checksums: List[Tuple[str, str]] = [
            ("ref_audio/original/" + original_audio_dest.name, sha256_file(original_audio_dest)),
            ("ref_text.txt", sha256_file(text_path)),
            ("variant.json", sha256_file(variant_root / "variant.json")),
        ]
        if normalized:
            variant_checksums.append(("ref_audio/normalized/ref_24000_mono.wav", sha256_file(normalized_audio_dest)))
        write_checksums(variant_root / "checksums.sha256", variant_checksums)

        variant_refs.append({"variantID": variant_id, "path": f"variants/{variant_id}/variant.json"})

    selection_catalog = build_selection_catalog(manifest, variants)
    write_json(profile_root / "selection-catalog.json", selection_catalog)

    metadata = {
        "schemaVersion": 1,
        "profileKind": "qwenBaseCloneReferenceProfile",
        "voiceID": manifest["voiceID"],
        "characterID": manifest["characterID"],
        "displayName": manifest.get("displayName", manifest["voiceID"]),
        "modelFamily": manifest.get("modelFamily", "qwen3-tts-base"),
        "modelID": manifest.get("modelID", "qwen3-tts-12hz-1.7b-base-4bit"),
        "quantization": manifest.get("quantization", "4bit"),
        "language": manifest.get("language", "english"),
        "defaultVariantID": manifest.get("defaultVariantID", variant_refs[0]["variantID"]),
        "allowFallback": False,
        "allowRuntimeRefAudioEncoding": True,
        "allowPrerecordedDialoguePlayback": False,
        "sourceProvider": manifest.get("sourceProvider", "elevenlabs"),
        "createdBy": "Tools/TuringVoicePackager/turing_voicepackager_mvp.py",
        "revision": "pending",
        "variants": variant_refs,
    }
    write_json(profile_root / "metadata.json", metadata)

    revision = profile_revision(profile_root)
    metadata["revision"] = f"sha256:{revision}"
    write_json(profile_root / "metadata.json", metadata)

    profile_checksum_entries = []
    for path in profile_root.rglob("*"):
        if path.is_file() and path.name != "checksums.sha256":
            profile_checksum_entries.append((str(path.relative_to(profile_root)).replace(os.sep, "/"), sha256_file(path)))
    write_checksums(profile_root / "checksums.sha256", profile_checksum_entries)

    log("wrote qwenclone profile", path=profile_root, revision=f"sha256:{revision}")

    if args.update_voice_registry:
        registry = root / "Gravitas Plague" / "TuringResources" / "Turing" / "Config" / "voice-registry.json"
        if args.voice_registry:
            registry = Path(args.voice_registry).expanduser()
            if not registry.is_absolute():
                registry = root / registry
        update_voice_registry(root, registry, profile_root, manifest, revision)

    return profile_root


def main() -> int:
    parser = argparse.ArgumentParser(description="Package Big Mike ElevenLabs reference audio into a .qwenclone profile.")
    parser.add_argument("--root", required=True, help="Repository root")
    parser.add_argument("--manifest", required=True, help="Manifest JSON path, absolute or repo-relative")
    parser.add_argument("--audio", default=None, help="Override source audio path")
    parser.add_argument("--profile-out", default=None, help="Override output .qwenclone path")
    parser.add_argument("--voice-registry", default=None, help="Override voice-registry.json path")
    parser.add_argument("--update-voice-registry", action="store_true", help="Update Turing voice-registry.json")
    parser.add_argument("--skip-normalize", action="store_true", help="Do not create 24 kHz mono WAV; inspection only")
    parser.add_argument("--clean", action="store_true", default=True, help="Delete existing profile output before writing")
    args = parser.parse_args()
    package_manifest(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
