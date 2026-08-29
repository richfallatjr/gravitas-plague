#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def size(root: Path) -> int:
    if root.is_file():
        return root.stat().st_size
    return sum(path.stat().st_size for path in root.rglob("*") if path.is_file())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    project = arguments.repository_root.resolve() / "Gravitas Plague"
    framework = project / "ThirdParty/TuringPocketSphinx/PocketSphinx.xcframework"
    resources = project / "TuringResources/Turing/RuntimeLipSync"
    result = {
        "deviceStaticLibraryBytes": size(
            framework / "xros-arm64/libTuringPocketSphinx.a"
        ),
        "simulatorStaticLibraryBytes": size(
            framework / "xros-arm64-simulator/libTuringPocketSphinx.a"
        ),
        "selectedRuntimeResourceBytes": size(
            resources / "pocketsphinx-5.1.1"
        ),
        "runtimeResourceTreeBytesIncludingManifests": size(resources),
    }
    result["provisionalDevicePayloadBytes"] = (
        result["deviceStaticLibraryBytes"]
        + result["runtimeResourceTreeBytesIncludingManifests"]
    )
    result["within16MiBGate"] = (
        result["provisionalDevicePayloadBytes"] <= 16 * 1024 * 1024
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["within16MiBGate"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
