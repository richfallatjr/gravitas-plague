#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


EXPECTED_RESOURCE_FILES = {
    "en-us/acoustic/README",
    "en-us/acoustic/feat.params",
    "en-us/acoustic/mdef",
    "en-us/acoustic/means",
    "en-us/acoustic/noisedict",
    "en-us/acoustic/sendump",
    "en-us/acoustic/transition_matrices",
    "en-us/acoustic/variances",
    "en-us/cmudict-en-us.dict",
    "en-us/en-us-phone.lm.bin",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_tree(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    root = arguments.repository_root.resolve()
    project = root / "Gravitas Plague"
    vendor = project / "ThirdParty/TuringPocketSphinx"
    resources = (
        project
        / "TuringResources/Turing/RuntimeLipSync/pocketsphinx-5.1.1"
    )
    lock = json.loads((vendor / "SourceLock.json").read_text())
    manifest = json.loads(
        (project / "TuringResources/Turing/RuntimeLipSync/manifest.json")
        .read_text()
    )
    actual_files = {
        path.relative_to(resources).as_posix()
        for path in resources.rglob("*")
        if path.is_file()
    }
    errors: list[str] = []
    if actual_files != EXPECTED_RESOURCE_FILES:
        errors.append(
            "resource file set mismatch: "
            f"missing={sorted(EXPECTED_RESOURCE_FILES - actual_files)} "
            f"extra={sorted(actual_files - EXPECTED_RESOURCE_FILES)}"
        )
    resource_bytes = sum(
        path.stat().st_size for path in resources.rglob("*") if path.is_file()
    )
    if resource_bytes != 10_742_421:
        errors.append(f"selected resource bytes: {resource_bytes}")
    if any(path.name == "en-us.lm.bin" for path in resources.rglob("*")):
        errors.append("forbidden general English language model is present")

    resource_hash = sha256_tree(resources)
    artifacts = lock["artifacts"]
    if artifacts["resourceTreeSHA256"] != resource_hash:
        errors.append("SourceLock resource tree hash mismatch")
    if manifest["resourceTreeSHA256"] != resource_hash:
        errors.append("runtime manifest resource tree hash mismatch")
    if manifest["selectedResourceBytes"] != resource_bytes:
        errors.append("runtime manifest selected byte count mismatch")

    framework = vendor / "PocketSphinx.xcframework"
    device = framework / "xros-arm64/libTuringPocketSphinx.a"
    simulator = framework / "xros-arm64-simulator/libTuringPocketSphinx.a"
    checks = {
        "deviceLibrarySHA256": sha256_file(device),
        "simulatorLibrarySHA256": sha256_file(simulator),
        "xcframeworkSHA256": sha256_tree(framework),
    }
    for key, value in checks.items():
        if artifacts[key] != value:
            errors.append(f"{key} mismatch: {value}")

    if "<generated>" in json.dumps(lock):
        errors.append("SourceLock contains a placeholder")
    for notice in (
        "POCKETSPHINX_LICENSE.txt",
        "POCKETSPHINX_ACOUSTIC_MODEL_NOTICE.txt",
        "CMU_DICTIONARY_NOTICE.txt",
    ):
        if not (vendor / "Licenses" / notice).is_file():
            errors.append(f"missing license notice: {notice}")

    report = {
        "status": "FAIL" if errors else "PASS",
        "resourceBytes": resource_bytes,
        "resourceTreeSHA256": resource_hash,
        "deviceLibraryBytes": device.stat().st_size,
        "simulatorLibraryBytes": simulator.stat().st_size,
        "xcframeworkSHA256": checks["xcframeworkSHA256"],
        "errors": errors,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
