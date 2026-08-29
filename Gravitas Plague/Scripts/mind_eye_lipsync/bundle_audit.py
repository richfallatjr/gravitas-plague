from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .hashing import sha256_file
from .set_index import expected_manifest_filenames
from .set_validator import validate_set


@dataclass(frozen=True, slots=True)
class BundleAuditResult:
    app_path: Path
    built_resource_directory: Path | None
    source_manifest_count: int
    bundled_manifest_count: int
    bundled_index: bool
    source_bundle_hash_match: bool
    forbidden_artifacts: tuple[str, ...]
    source_set_bytes: int
    built_set_bytes: int
    largest_manifest: str
    smallest_manifest: str
    index_bytes: int

    @property
    def is_valid(self) -> bool:
        return (
            self.source_manifest_count == 37
            and self.bundled_manifest_count == 37
            and self.bundled_index
            and self.source_bundle_hash_match
            and not self.forbidden_artifacts
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": "PASS" if self.is_valid else "FAIL",
            "valid": self.is_valid,
            "appPath": self.app_path.as_posix(),
            "builtResourceDirectory": self.built_resource_directory.as_posix() if self.built_resource_directory else None,
            "sourceManifestCount": self.source_manifest_count,
            "bundledManifestCount": self.bundled_manifest_count,
            "bundledIndex": self.bundled_index,
            "sourceBundleHashMatch": self.source_bundle_hash_match,
            "forbiddenAuthoringArtifacts": list(self.forbidden_artifacts),
            "sourceSetBytes": self.source_set_bytes,
            "builtSetBytes": self.built_set_bytes,
            "largestManifest": self.largest_manifest,
            "smallestManifest": self.smallest_manifest,
            "indexBytes": self.index_bytes,
            "bundleSizeDeltaBytes": self.built_set_bytes,
            "thinnedAppStoreSizeMeasured": False,
        }


def _resolve_built_directory(app: Path) -> Path | None:
    candidates = [
        path for path in app.rglob("AudioFrames")
        if path.is_dir() and path.parent.name == "MindsEye"
    ]
    if len(candidates) == 1:
        return candidates[0]
    return None


def audit_bundle(app: Path, source_directory: Path, *, expected_count: int = 37) -> BundleAuditResult:
    if expected_count != 37:
        raise ValueError("Phase 7 bundle audit requires expected_count == 37")
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError(f"Built app does not exist: {app}")
    source_validation = validate_set(source_directory, verify_sources=True)
    if not source_validation.is_valid:
        raise ValueError("Source production set is invalid")
    expected = set(expected_manifest_filenames()) | {"index.json"}
    built_directory = _resolve_built_directory(app)
    built_names: set[str] = set()
    hash_match = False
    built_bytes = 0
    if built_directory is not None:
        built_files = [path for path in built_directory.iterdir() if path.is_file() and not path.is_symlink()]
        built_names = {path.name for path in built_files}
        built_bytes = sum(path.stat().st_size for path in built_files)
        hash_match = built_names == expected and all(
            sha256_file(source_directory / name) == sha256_file(built_directory / name)
            for name in expected
        )

    forbidden: list[str] = []
    forbidden_names = {
        "mfa-environment.yml", "requirements.lock.txt", "toolchain.lock.json",
        "review-data.json", "review-decisions.json",
    }
    forbidden_suffixes = {".textgrid", ".onnx", ".svg", ".html", ".css", ".py", ".pyc", ".yml"}
    for path in app.rglob("*"):
        if not path.is_file():
            continue
        lower_name = path.name.lower()
        lower_parts = {part.lower() for part in path.parts}
        if path.name in forbidden_names:
            forbidden.append(path.relative_to(app).as_posix())
            continue
        if path.suffix.lower() in forbidden_suffixes and (
            "mindseye" in lower_parts or "mfa" in lower_name or "silero" in lower_name
        ):
            forbidden.append(path.relative_to(app).as_posix())
            continue
        if "mindseye" in lower_parts and path.suffix.lower() in {".wav", ".mp3", ".flac"}:
            forbidden.append(path.relative_to(app).as_posix())
            continue
        if any(token in lower_name for token in ("silero", "kaldi", "textgrid", "vad-windows", "mfa-output")):
            forbidden.append(path.relative_to(app).as_posix())

    source_manifests = sorted(source_directory.glob("*.mouthframes.json"), key=lambda path: path.stat().st_size)
    return BundleAuditResult(
        app_path=app,
        built_resource_directory=built_directory,
        source_manifest_count=len(source_manifests),
        bundled_manifest_count=len([name for name in built_names if name.endswith(".mouthframes.json")]),
        bundled_index="index.json" in built_names,
        source_bundle_hash_match=hash_match,
        forbidden_artifacts=tuple(sorted(set(forbidden))),
        source_set_bytes=sum(path.stat().st_size for path in source_directory.iterdir() if path.is_file()),
        built_set_bytes=built_bytes,
        largest_manifest=source_manifests[-1].name,
        smallest_manifest=source_manifests[0].name,
        index_bytes=(source_directory / "index.json").stat().st_size,
    )

