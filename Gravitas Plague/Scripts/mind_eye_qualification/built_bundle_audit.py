from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Any

from .source_audit import audit_source, sha256


FORBIDDEN_BUILT_MARKERS = (
    "mind_eye_lipsync", "montreal", "silero", "onnx", "mfa-environment",
    "qualification.json", "manual_visual_review", "debug-overlay",
)


def _matching_files(root: Path, name: str) -> list[Path]:
    return sorted(item for item in root.rglob(name) if item.is_file())


def audit_built_app(repository_root: Path, app_path: Path) -> dict[str, Any]:
    app_path = app_path.resolve()
    source = audit_source(repository_root)
    errors = [] if source["status"] == "PASS" else ["source audit must pass first"]
    if not app_path.is_dir() or app_path.suffix != ".app":
        return {"status": "FAIL", "errors": [f"invalid app path: {app_path}"]}
    app_files = sorted(item for item in app_path.rglob("*") if item.is_file())
    lowered = [item.relative_to(app_path).as_posix().lower() for item in app_files]
    for relative in lowered:
        if any(marker in relative for marker in FORBIDDEN_BUILT_MARKERS):
            errors.append(f"forbidden built artifact: {relative}")
    source_by_name: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in source.get("files", []):
        source_by_name[Path(record["path"]).name].append(record)
    verified = []
    for name in ("catalog.json", "manifest.json", "index.json"):
        expected = source_by_name.get(name, [])
        candidates = _matching_files(app_path, name)
        for record in expected:
            matching = [item for item in candidates if sha256(item) == record["sha256"]]
            if len(matching) != 1:
                errors.append(f"expected one built copy of {record['path']}, found {len(matching)}")
            else:
                verified.append(record["path"])
    png_source = [record for record in source.get("files", []) if record["path"].lower().endswith(".png")]
    png_hash_counts: dict[str, int] = defaultdict(int)
    for item in app_files:
        if item.suffix.lower() == ".png":
            png_hash_counts[sha256(item)] += 1
    for record in png_source:
        count = png_hash_counts[record["sha256"]]
        if count != 1:
            errors.append(f"expected one built PNG copy of {record['path']}, found {count}")
    built_manifests = [item for item in app_files if item.name.endswith(".mouthframes.json")]
    if len(built_manifests) != 37:
        errors.append(f"expected 37 built authored manifests, found {len(built_manifests)}")
    return {
        "schemaVersion": 1,
        "status": "PASS" if not errors else "FAIL",
        "appPath": str(app_path),
        "appBytes": sum(item.stat().st_size for item in app_files),
        "sourceMindEyeBytes": source.get("totalBytes"),
        "builtAuthoredManifestCount": len(built_manifests),
        "verifiedControlFiles": sorted(verified),
        "errors": errors,
    }


def find_unique_app(search_root: Path) -> Path:
    apps = sorted(item for item in search_root.rglob("*.app") if item.is_dir())
    if len(apps) != 1:
        raise ValueError(f"expected one built app under {search_root}, found {len(apps)}")
    return apps[0]
