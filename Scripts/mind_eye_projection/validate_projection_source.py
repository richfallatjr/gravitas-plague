#!/usr/bin/env python3
"""Dependency-free validation for the shipped Angel facial-projection package."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import struct
import sys


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
RESOURCE_ROOT = pathlib.Path("Gravitas Plague/TuringResources")
PROFILE_PATH = RESOURCE_ROOT / "Turing/MindsEye/Projection/profiles/angel_head_v1.json"


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: pathlib.Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def chunks(data: bytes):
    if data[:8] != PNG_SIGNATURE:
        raise ValueError("invalid PNG signature")
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        if len(payload) != length:
            raise ValueError("truncated PNG chunk")
        yield kind, payload
        offset += 12 + length
        if kind == b"IEND":
            return
    raise ValueError("missing PNG IEND")


def inspect_png(path: pathlib.Path) -> tuple[tuple[int, int, int, int], bytes]:
    data = path.read_bytes()
    parsed = list(chunks(data))
    if not parsed or parsed[0][0] != b"IHDR" or len(parsed[0][1]) != 13:
        raise ValueError(f"{path.name}: invalid IHDR")
    width, height, depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", parsed[0][1]
    )
    if compression != 0 or filtering != 0 or interlace != 0:
        raise ValueError(f"{path.name}: unsupported PNG encoding")
    return (width, height, depth, color_type), b"".join(
        payload for kind, payload in parsed if kind == b"IDAT"
    )


def alpha_range(path: pathlib.Path, width: int, height: int) -> tuple[int, int]:
    result = subprocess.run(
        [
            "ffmpeg", "-v", "error", "-i", str(path),
            "-vf", "alphaextract", "-frames:v", "1",
            "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1",
        ],
        check=True,
        capture_output=True,
    )
    if len(result.stdout) != width * height:
        raise ValueError(f"{path.name}: decoded alpha byte count is invalid")
    return min(result.stdout), max(result.stdout)


def resource(repository: pathlib.Path, relative: str) -> pathlib.Path:
    path = (repository / RESOURCE_ROOT / relative).resolve()
    root = (repository / RESOURCE_ROOT).resolve()
    if root not in path.parents or not path.is_file():
        raise ValueError(f"missing or unsafe resource: {relative}")
    return path


def validate(repository: pathlib.Path) -> dict:
    profile_path = repository / PROFILE_PATH
    profile = load_json(profile_path)
    manifest_path = resource(repository, profile["plateManifestResourcePath"])
    manifest = load_json(manifest_path)
    if manifest["schemaVersion"] != 1 or manifest["packageID"] != "angel_head_v1":
        raise ValueError("invalid package identity")
    expected_geometry = (1728, 1728, 8, 6)
    if (profile["sourceWidth"], profile["sourceHeight"], profile["cropOriginX"],
            profile["cropOriginY"], profile["viewportWidth"], profile["viewportHeight"]) != (
            1728, 1728, 144, 144, 1440, 1440):
        raise ValueError("profile does not preserve the locked square crop")

    identity_paths = {
        "profileSHA256": profile_path,
        "cameraSHA256": resource(repository, profile["cameraResourcePath"]),
        "targetSHA256": resource(repository, profile["targetResourcePath"]),
        "subjectAssetSHA256": repository / manifest["subjectAssetName"],
    }
    for field, path in identity_paths.items():
        if not path.is_file() or sha256(path) != manifest[field]:
            raise ValueError(f"{field} is stale")

    families = manifest["mouths"]
    if set(families) != {"rest", "small", "wide", "round", "teeth"}:
        raise ValueError("all five mouth families, including teeth, are required")
    lists = [manifest["eyes"]["open"], manifest["eyes"]["closed"]]
    lists.extend(families[name] for name in ("rest", "small", "wide", "round", "teeth"))
    if any(not values for values in lists):
        raise ValueError("an eye or mouth family is empty")
    layers = [manifest["projectionBase"]] + [item for values in lists for item in values]
    filenames = [layer["filename"] for layer in layers]
    if len(filenames) != len(set(filenames)):
        raise ValueError("duplicate plate filename")
    directory = manifest_path.parent
    if set(path.name for path in directory.glob("*.png")) != set(filenames):
        raise ValueError("unmanifested or missing projection plate PNG")

    for index, layer in enumerate(layers):
        if pathlib.Path(layer["filename"]).name != layer["filename"]:
            raise ValueError("plate filename escaped its package")
        path = directory / layer["filename"]
        header, _ = inspect_png(path)
        if header != expected_geometry:
            raise ValueError(f"{path.name}: expected 1728x1728 8-bit RGBA, found {header}")
        if sha256(path) != layer["SHA256"]:
            raise ValueError(f"{path.name}: SHA256 mismatch")
        minimum, maximum = alpha_range(path, 1728, 1728)
        if index == 0 and (minimum, maximum) != (255, 255):
            raise ValueError("projection-base.png must be fully opaque")
        if index > 0 and not (minimum == 0 and maximum > 0):
            raise ValueError(f"{path.name}: overlay must contain transparent and visible pixels")

    mask = manifest["projectionMask"]
    mask_path = resource(repository, mask["resourcePath"])
    header, _ = inspect_png(mask_path)
    if header != (1440, 1440, 16, 0):
        raise ValueError(f"projection mask must be 1440x1440 16-bit gray, found {header}")
    if sha256(mask_path) != mask["SHA256"] or mask["SHA256"] != profile["projectionMaskSHA256"]:
        raise ValueError("projection mask SHA256 mismatch")

    return {
        "status": "PASS",
        "packageID": manifest["packageID"],
        "plateCount": len(layers),
        "mouthFamilies": sorted(families),
        "sourceDimensions": [1728, 1728],
        "viewportDimensions": [1440, 1440],
        "cropOrigin": [144, 144],
        "projectionMaskSHA256": mask["SHA256"],
        "estimatedRGBA8SourceBytes": len(layers) * 1728 * 1728 * 4,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=pathlib.Path, default=pathlib.Path(__file__).parents[2])
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.repository_root.resolve()), indent=2, sort_keys=True))
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
