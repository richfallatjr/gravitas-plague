from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


FORBIDDEN_RESOURCE_MARKERS = (
    "mfa", "montreal", "silero", "onnx", "python", "conda", "venv",
    "qualification.json", ".html", ".svg", "packed", "cropped",
)


def sha256(file_path: Path) -> str:
    digest = hashlib.sha256()
    with file_path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def audit_source(repository_root: Path) -> dict[str, Any]:
    repository_root = repository_root.resolve()
    resource_root = repository_root / "Gravitas Plague/TuringResources/Turing/MindsEye"
    errors: list[str] = []
    if not resource_root.is_dir():
        return {"status": "FAIL", "errors": [f"missing {resource_root}"], "files": []}
    files = sorted(item for item in resource_root.rglob("*") if item.is_file() or item.is_symlink())
    records = []
    hashes: dict[str, list[str]] = defaultdict(list)
    for item in files:
        relative = item.relative_to(resource_root).as_posix()
        if item.is_symlink():
            errors.append(f"symlink forbidden: {relative}")
            continue
        size = item.stat().st_size
        if size == 0:
            errors.append(f"zero-byte resource: {relative}")
        digest = sha256(item)
        hashes[digest].append(relative)
        records.append({"path": relative, "bytes": size, "sha256": digest})
        lowered = relative.lower()
        if any(marker in lowered for marker in FORBIDDEN_RESOURCE_MARKERS):
            errors.append(f"authoring/qualification/packed artifact forbidden: {relative}")
    png_duplicates = [paths for paths in hashes.values() if len(paths) > 1 and all(path.lower().endswith(".png") for path in paths)]
    for paths in png_duplicates:
        errors.append("duplicate PNG bytes: " + ", ".join(paths))
    audio_duplicates = [paths for paths in hashes.values() if len(paths) > 1 and all(Path(path).suffix.lower() in {".wav", ".mp3", ".m4a", ".aif", ".aiff"} for path in paths)]
    for paths in audio_duplicates:
        errors.append("duplicate audio bytes: " + ", ".join(paths))
    frames = resource_root / "AudioFrames"
    manifests = sorted(frames.glob("*.mouthframes.json")) if frames.is_dir() else []
    indexes = sorted(frames.glob("index.json")) if frames.is_dir() else []
    if len(manifests) != 37:
        errors.append(f"expected 37 authored manifests, found {len(manifests)}")
    if len(indexes) != 1:
        errors.append(f"expected one authored index, found {len(indexes)}")
    audio_frame_directories = [item for item in resource_root.rglob("AudioFrames") if item.is_dir()]
    if len(audio_frame_directories) != 1:
        errors.append(f"expected one AudioFrames directory, found {len(audio_frame_directories)}")
    vignette_manifests = sorted(resource_root.glob("Vignettes/*/manifest.json"))
    catalog = resource_root / "catalog.json"
    if not catalog.is_file():
        errors.append("catalog.json is missing")
    else:
        try:
            descriptor = json.loads(catalog.read_text(encoding="utf-8"))
            expected_vignettes = sum(
                len(entry.get("vignettes", []))
                for entry in descriptor.get("entries", [])
                if isinstance(entry, dict)
            )
            if len(vignette_manifests) != expected_vignettes:
                errors.append(
                    "catalog declares "
                    f"{expected_vignettes} vignette package(s), found {len(vignette_manifests)}"
                )
        except (OSError, json.JSONDecodeError, AttributeError) as error:
            errors.append(f"invalid JSON catalog.json: {error}")
    for json_file in [catalog, *vignette_manifests, *indexes, *manifests]:
        if json_file.is_file():
            try:
                json.loads(json_file.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                errors.append(f"invalid JSON {json_file.relative_to(resource_root)}: {error}")
    return {
        "schemaVersion": 1,
        "status": "PASS" if not errors else "FAIL",
        "resourceRoot": str(resource_root),
        "totalBytes": sum(record["bytes"] for record in records),
        "fileCount": len(records),
        "pngCount": sum(record["path"].lower().endswith(".png") for record in records),
        "authoredManifestCount": len(manifests),
        "indexCount": len(indexes),
        "duplicatePNGGroups": png_duplicates,
        "duplicateAudioGroups": audio_duplicates,
        "files": records,
        "errors": errors,
    }
