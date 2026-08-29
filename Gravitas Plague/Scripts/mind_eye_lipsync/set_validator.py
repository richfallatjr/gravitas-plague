from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any

from .deterministic_json import canonical_json_bytes
from .errors import Diagnostic
from .hashing import sha256_file
from .registry import load_registry
from .set_index import (
    EXPECTED_MANIFEST_COUNT,
    build_index_payload,
    expected_manifest_filenames,
    manifest_set_sha256,
    validate_index_object,
)
from .validator import validate_manifest_file, verify_current_sources


@dataclass(frozen=True, slots=True)
class SetValidationSummary:
    manifest_count: int
    expected_count: int
    unique_pr_id_count: int
    exclusion_count_found: int
    orphan_count: int
    malformed_count: int
    stale_source_count: int
    mixed_provenance_count: int
    set_hash_matches: bool
    index_matches: bool
    total_bytes: int
    diagnostics: tuple[Diagnostic, ...]

    @property
    def is_valid(self) -> bool:
        return (
            self.manifest_count == EXPECTED_MANIFEST_COUNT
            and self.expected_count == EXPECTED_MANIFEST_COUNT
            and self.unique_pr_id_count == EXPECTED_MANIFEST_COUNT
            and self.exclusion_count_found == 0
            and self.orphan_count == 0
            and self.malformed_count == 0
            and self.stale_source_count == 0
            and self.mixed_provenance_count == 0
            and self.set_hash_matches
            and self.index_matches
            and not any(item.severity == "error" for item in self.diagnostics)
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": "PASS" if self.is_valid else "FAIL",
            "valid": self.is_valid,
            "manifestCount": self.manifest_count,
            "expectedCount": self.expected_count,
            "uniquePRIDCount": self.unique_pr_id_count,
            "exclusionCountFound": self.exclusion_count_found,
            "orphanCount": self.orphan_count,
            "malformedCount": self.malformed_count,
            "staleSourceCount": self.stale_source_count,
            "mixedProvenanceCount": self.mixed_provenance_count,
            "setHashMatches": self.set_hash_matches,
            "indexMatches": self.index_matches,
            "totalBytes": self.total_bytes,
            "diagnostics": [
                {
                    "code": item.code,
                    "message": item.message,
                    "severity": item.severity,
                    "prID": item.pr_id,
                    "path": item.path,
                }
                for item in self.diagnostics
            ],
        }


def _diagnostic(code: str, message: str, *, path: Path | None = None, pr_id: str | None = None, severity: str = "error") -> Diagnostic:
    return Diagnostic(code=code, message=message, severity=severity, pr_id=pr_id, path=path.as_posix() if path else None)


def validate_set(
    directory: Path,
    *,
    verify_sources: bool,
    expected_count: int = EXPECTED_MANIFEST_COUNT,
) -> SetValidationSummary:
    if expected_count != EXPECTED_MANIFEST_COUNT:
        raise ValueError("Phase 7 complete-set validation requires expected_count == 37")
    if not directory.is_dir():
        raise ValueError(f"Production set directory does not exist: {directory}")

    registry = load_registry()
    expected_names = set(expected_manifest_filenames(registry))
    diagnostics: list[Diagnostic] = []
    regular_files: list[Path] = []
    for path in sorted(directory.iterdir(), key=lambda item: item.name):
        if path.is_symlink():
            diagnostics.append(_diagnostic("symlinkPresent", "Symlinks are forbidden in AudioFrames", path=path))
        elif path.is_dir():
            diagnostics.append(_diagnostic("nestedDirectory", "Nested directories are forbidden in AudioFrames", path=path))
        elif path.is_file():
            regular_files.append(path)
            if path.name.startswith("."):
                diagnostics.append(_diagnostic("hiddenFile", "Hidden files are forbidden in AudioFrames", path=path))
        else:
            diagnostics.append(_diagnostic("nonRegularEntry", "Only regular files are allowed in AudioFrames", path=path))

    names = [path.name for path in regular_files]
    if len({name.casefold() for name in names}) != len(names):
        diagnostics.append(_diagnostic("caseFoldCollision", "AudioFrames filenames are not case-fold unique"))
    allowed_names = expected_names | {"index.json"}
    for path in regular_files:
        if path.name not in allowed_names:
            diagnostics.append(_diagnostic("unexpectedFile", "Unexpected file in AudioFrames", path=path))
    index_paths = [path for path in regular_files if path.name == "index.json"]
    if len(index_paths) != 1:
        diagnostics.append(_diagnostic("indexCount", f"Expected one index.json, found {len(index_paths)}"))

    manifest_paths = sorted(
        (path for path in regular_files if path.name.endswith(".mouthframes.json")),
        key=lambda path: path.name,
    )
    present_names = {path.name for path in manifest_paths}
    missing_names = sorted(expected_names - present_names)
    orphan_names = sorted(present_names - expected_names)
    if missing_names:
        diagnostics.append(_diagnostic("missingManifests", f"Missing production manifests: {missing_names}"))
    if orphan_names:
        diagnostics.append(_diagnostic("orphanManifests", f"Orphan manifests: {orphan_names}"))

    decoded: list[dict[str, Any]] = []
    malformed = 0
    stale = 0
    for path in manifest_paths:
        try:
            payload = validate_manifest_file(path, verify_sources=False)
            if path.name != f"{payload['prID']}.mouthframes.json":
                raise ValueError("Filename does not match manifest PR ID")
            decoded.append(payload)
            if verify_sources:
                try:
                    verify_current_sources(payload)
                except Exception as error:
                    stale += 1
                    diagnostics.append(_diagnostic("staleSource", str(error), path=path, pr_id=str(payload.get("prID"))))
        except Exception as error:
            malformed += 1
            diagnostics.append(_diagnostic("malformedManifest", str(error), path=path))

    ids = [str(payload["prID"]) for payload in decoded]
    exclusions_found = sorted(set(ids) & registry.excluded_ids)
    if exclusions_found:
        diagnostics.append(_diagnostic("excludedManifest", f"Excluded PRs present: {exclusions_found}"))

    provenance_keys = (
        "toolchainLockSHA256", "compilerConfigSHA256",
        "phonemePoseMapSHA256", "pronunciationOverridesSHA256",
    )
    mixed = 0
    if decoded:
        baseline = decoded[0]
        baseline_tuple = (
            baseline["schemaVersion"], baseline["compilerVersion"],
            *(baseline["analysisProvenance"][key] for key in provenance_keys),
            *(
                baseline["analysisProvenance"]["mfa"][key]
                for key in ("version", "acousticModelVersion", "dictionaryVersion", "g2pModelVersion")
            ),
            *(
                baseline["analysisProvenance"]["vad"][key]
                for key in ("name", "version", "backend", "modelSHA256", "configurationSHA256")
            ),
        )
        for payload in decoded[1:]:
            candidate = (
                payload["schemaVersion"], payload["compilerVersion"],
                *(payload["analysisProvenance"][key] for key in provenance_keys),
                *(
                    payload["analysisProvenance"]["mfa"][key]
                    for key in ("version", "acousticModelVersion", "dictionaryVersion", "g2pModelVersion")
                ),
                *(
                    payload["analysisProvenance"]["vad"][key]
                    for key in ("name", "version", "backend", "modelSHA256", "configurationSHA256")
                ),
            )
            if candidate != baseline_tuple:
                mixed += 1
        if mixed:
            diagnostics.append(_diagnostic("mixedProvenance", f"{mixed} manifests differ from the set provenance"))

    index_payload: dict[str, Any] | None = None
    index_matches = False
    set_hash_matches = False
    if len(index_paths) == 1:
        try:
            parsed = json.loads(index_paths[0].read_text(encoding="utf-8"))
            if not isinstance(parsed, dict):
                raise ValueError("index.json root must be an object")
            validate_index_object(parsed)
            index_payload = parsed
        except Exception as error:
            diagnostics.append(_diagnostic("indexInvalid", str(error), path=index_paths[0]))

    complete_files = len(manifest_paths) == EXPECTED_MANIFEST_COUNT and present_names == expected_names and malformed == 0
    if complete_files and index_payload is not None:
        computed_hash = manifest_set_sha256(directory, sorted(expected_names))
        set_hash_matches = index_payload["manifestSetSHA256"] == computed_hash
        if not set_hash_matches:
            diagnostics.append(_diagnostic("setHashMismatch", "index.json manifestSetSHA256 does not match manifest bytes"))
        try:
            rebuilt = build_index_payload(
                directory,
                registry=registry,
                verify_sources=verify_sources,
            )
            index_matches = canonical_json_bytes(rebuilt) == index_paths[0].read_bytes()
            if not index_matches:
                diagnostics.append(_diagnostic("indexContentMismatch", "index.json is not the deterministic index for these manifests"))
        except Exception as error:
            diagnostics.append(_diagnostic("indexRebuildFailed", str(error)))

    manifest_bytes = sum(path.stat().st_size for path in manifest_paths)
    index_bytes = sum(path.stat().st_size for path in index_paths)
    if any(path.stat().st_size > 8 * 1024 * 1024 for path in manifest_paths):
        diagnostics.append(_diagnostic("largeManifest", "At least one manifest exceeds 8 MiB", severity="warning"))
    if manifest_bytes > 64 * 1024 * 1024:
        diagnostics.append(_diagnostic("largeManifestSet", "Manifest set exceeds 64 MiB", severity="warning"))
    if manifest_bytes > 128 * 1024 * 1024:
        diagnostics.append(_diagnostic("manifestSetTooLarge", "Manifest set exceeds the 128 MiB hard limit"))
    if index_bytes > 512 * 1024:
        diagnostics.append(_diagnostic("largeIndex", "index.json exceeds 512 KiB", severity="warning"))

    return SetValidationSummary(
        manifest_count=len(manifest_paths),
        expected_count=expected_count,
        unique_pr_id_count=len(set(ids)),
        exclusion_count_found=len(exclusions_found),
        orphan_count=len(orphan_names),
        malformed_count=malformed,
        stale_source_count=stale,
        mixed_provenance_count=mixed,
        set_hash_matches=set_hash_matches,
        index_matches=index_matches,
        total_bytes=manifest_bytes + index_bytes,
        diagnostics=tuple(sorted(diagnostics, key=lambda item: (item.severity, item.code, item.path or ""))),
    )
