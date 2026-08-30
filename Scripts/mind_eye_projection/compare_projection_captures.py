#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import subprocess


EXACT = (
    "angel_head_v1_camera.json",
    "angel_head_v1_projection-mask-linear16.png",
    "angel_head_v1_projection-mask-preview.png",
    "angel_head_v1_alignment-guide.png",
)
BEAUTY = (
    "angel_head_v1_scene-beauty.png",
    "angel_head_v1_face-beauty.png",
)


def digest(path: str) -> str:
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def rgba(path: str) -> bytes:
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgba", "-"],
        check=True,
        capture_output=True,
    )
    return result.stdout


def compare_beauty(first: str, second: str):
    left = rgba(first)
    right = rgba(second)
    if len(left) != len(right) or not left:
        raise SystemExit(f"Beauty dimensions differ: {os.path.basename(first)}")
    differences = [abs(a - b) for a, b in zip(left, right)]
    maximum = max(differences)
    mse = sum(value * value for value in differences) / len(differences)
    psnr = math.inf if mse == 0 else 10 * math.log10((255 * 255) / mse)
    if maximum > 1 or psnr < 60:
        raise SystemExit(
            f"Beauty comparison failed for {os.path.basename(first)}: max={maximum}, PSNR={psnr:.3f} dB"
        )
    return maximum, psnr


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("first")
    parser.add_argument("second")
    args = parser.parse_args()
    failures = []
    for filename in EXACT:
        if digest(os.path.join(args.first, filename)) != digest(os.path.join(args.second, filename)):
            failures.append(filename)
    if failures:
        raise SystemExit("Deterministic outputs differ: " + ", ".join(failures))
    metrics = {}
    for filename in BEAUTY:
        maximum, psnr = compare_beauty(
            os.path.join(args.first, filename),
            os.path.join(args.second, filename),
        )
        metrics[filename] = {"maximumAbsoluteError": maximum, "PSNR": psnr}
    for directory in (args.first, args.second):
        manifest = os.path.join(directory, "angel_head_v1_capture-manifest.json")
        if not os.path.isfile(manifest):
            raise SystemExit(f"Missing capture manifest: {manifest}")
    first_manifest = json.load(open(os.path.join(args.first, "angel_head_v1_capture-manifest.json")))
    second_manifest = json.load(open(os.path.join(args.second, "angel_head_v1_capture-manifest.json")))
    for key in ("profileSHA256", "targetSHA256", "cameraSHA256"):
        if first_manifest.get(key) != second_manifest.get(key):
            raise SystemExit(f"Capture manifest identity differs: {key}")
    print(json.dumps({"decision": "PASS", "beauty": metrics}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
