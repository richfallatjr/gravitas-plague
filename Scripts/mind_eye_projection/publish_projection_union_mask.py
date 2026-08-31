#!/usr/bin/env python3
"""Publish the validated four-pose union mask into the runtime package.

The capture renderer works at the locked 1728-square source size. Production
consumes the exact centered 1440-square crop. This host-only publisher stages
the mask and every affected hash contract before replacing any runtime file.
"""

import argparse
import hashlib
import json
import os
import pathlib
import struct
import subprocess
import tempfile


def sha256(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def read_json(path: pathlib.Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: pathlib.Path, value: dict) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def png_contract(path: pathlib.Path) -> tuple[int, int, int, int]:
    with path.open("rb") as handle:
        header = handle.read(26)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"not a PNG: {path}")
    return struct.unpack(">IIBB", header[16:26])


def publish(repository: pathlib.Path, capture: pathlib.Path) -> dict:
    runtime = repository / "Gravitas Plague/TuringResources/Turing/MindsEye/Projection"
    profile_path = runtime / "profiles/angel_head_v1.json"
    manifest_path = runtime / "plates/angel_head_v1/source-manifest.json"
    capture_manifest_path = capture / "angel_head_v1_capture-manifest.json"
    union_path = (
        capture / "GeometryPoses/angel_head_v1_projection-mask-union-linear16.png"
    )
    for path in (profile_path, manifest_path, capture_manifest_path, union_path):
        if not path.is_file():
            raise FileNotFoundError(path)

    profile = read_json(profile_path)
    plate_manifest = read_json(manifest_path)
    capture_manifest = read_json(capture_manifest_path)
    crop_x = int(profile["cropOriginX"])
    crop_y = int(profile["cropOriginY"])
    width = int(profile["viewportWidth"])
    height = int(profile["viewportHeight"])
    output_path = repository / "Gravitas Plague/TuringResources" / profile[
        "projectionMaskResourcePath"
    ]

    with tempfile.TemporaryDirectory(prefix="angel-union-mask-") as raw:
        staging = pathlib.Path(raw)
        staged_mask = staging / output_path.name
        subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-i", str(union_path),
                "-vf", f"crop={width}:{height}:{crop_x}:{crop_y}",
                "-pix_fmt", "gray16be", str(staged_mask),
            ],
            check=True,
        )
        if png_contract(staged_mask) != (width, height, 16, 0):
            raise ValueError("staged runtime mask does not satisfy the 16-bit contract")
        mask_hash = sha256(staged_mask)

        profile["projectionMaskSHA256"] = mask_hash
        staged_profile = staging / profile_path.name
        write_json(staged_profile, profile)
        profile_hash = sha256(staged_profile)

        plate_manifest["profileSHA256"] = profile_hash
        plate_manifest["projectionMask"]["SHA256"] = mask_hash
        staged_manifest = staging / manifest_path.name
        write_json(staged_manifest, plate_manifest)

        capture_manifest["profileSHA256"] = profile_hash
        staged_capture_manifest = staging / capture_manifest_path.name
        write_json(staged_capture_manifest, capture_manifest)

        output_path.parent.mkdir(parents=True, exist_ok=True)
        os.replace(staged_mask, output_path)
        os.replace(staged_profile, profile_path)
        os.replace(staged_manifest, manifest_path)
        os.replace(staged_capture_manifest, capture_manifest_path)

    return {
        "status": "PASS",
        "projectionMaskSHA256": mask_hash,
        "profileSHA256": profile_hash,
        "runtimeMask": str(output_path),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--capture-directory", required=True)
    args = parser.parse_args()
    report = publish(
        pathlib.Path(args.repository_root).resolve(),
        pathlib.Path(args.capture_directory).resolve(),
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
