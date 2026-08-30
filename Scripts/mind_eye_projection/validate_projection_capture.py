#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import struct
import sys


REQUIRED = {
    "angel_head_v1_scene-beauty.png": (1728, 1728, 8),
    "angel_head_v1_face-beauty.png": (1728, 1728, 8),
    "angel_head_v1_projection-mask-aov.png": (1728, 1728, 8),
    "angel_head_v1_projection-mask-linear16.png": (1728, 1728, 16),
    "angel_head_v1_projection-mask-preview.png": (1728, 1728, 8),
    "angel_head_v1_alignment-guide.png": (1728, 1728, 8),
    "angel_head_v1_camera.json": None,
    "angel_head_v1_capture-manifest.json": None,
    "angel_head_v1_scene-hierarchy.txt": None,
    "angel_head_v1_complete.json": None,
}


def sha256(path: str) -> str:
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def png_header(path: str):
    with open(path, "rb") as handle:
        header = handle.read(33)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"{path} is not a PNG")
    width, height, bits, color_type = struct.unpack(">IIBB", header[16:26])
    return width, height, bits, color_type


def source_audit(root: str) -> None:
    app_source = os.path.join(root, "Gravitas Plague", "Gravitas Plague")
    scripts = os.path.join(root, "Scripts", "mind_eye_projection")
    forbidden = ("osascript", "cliclick", "screenshot")
    with open(os.path.join(scripts, "capture_angel_projection_reference.sh"), encoding="utf-8") as handle:
        shell = handle.read().lower()
    for token in forbidden:
        if token in shell:
            raise SystemExit(f"Source audit failed: host script contains {token}")
    projection_root = os.path.join(app_source, "Turing", "MindsEye", "Projection")
    for current, _, files in os.walk(projection_root):
        for filename in files:
            if not filename.endswith((".swift", ".metal")):
                continue
            text = open(os.path.join(current, filename), encoding="utf-8").read()
            if "2_048" in text or "2048" in text:
                raise SystemExit(f"Source audit failed: unapproved 2048 square in {filename}")
    cameras = []
    camera_root = os.path.join(
        root, "Gravitas Plague", "TuringResources", "Turing", "MindsEye", "Projection", "cameras"
    )
    for current, _, files in os.walk(camera_root):
        cameras.extend(os.path.join(current, f) for f in files if f == "angel_head_v1.camera.json")
    if len(cameras) != 1:
        raise SystemExit(f"Source audit failed: expected one canonical camera, found {len(cameras)}")
    print("Mind's Eye projection source audit: PASS")


def validate(directory: str, runtime_camera: str) -> None:
    for filename, image_contract in REQUIRED.items():
        path = os.path.join(directory, filename)
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            raise SystemExit(f"Missing or empty required output: {path}")
        if image_contract:
            actual = png_header(path)
            expected = image_contract
            if actual[:3] != expected:
                raise SystemExit(f"PNG contract mismatch for {filename}: {actual} != {expected}")
            if filename.endswith("linear16.png") and actual[3] != 0:
                raise SystemExit("Linear16 mask must be grayscale PNG color type 0.")
    manifest_path = os.path.join(directory, "angel_head_v1_capture-manifest.json")
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("captureState") != "frameZero" or manifest.get("animationAdvancedFrames") != 0:
        raise SystemExit("Capture was not produced at deterministic frame zero.")
    coverage = float(manifest.get("maskCoverageFraction", -1))
    if not 0.12 <= coverage <= 0.80:
        raise SystemExit(f"Mask coverage outside contract: {coverage}")
    if any(abs(float(v)) > 1728 * 0.02 for v in manifest.get("maskCenterErrorPixels", [])):
        raise SystemExit("Mask center error exceeds 2%.")
    outputs = {item["filename"]: item for item in manifest.get("outputs", [])}
    for filename, output in outputs.items():
        path = os.path.join(directory, filename)
        if not os.path.isfile(path):
            raise SystemExit(f"Manifest output is missing: {filename}")
        if output.get("SHA256") != sha256(path) or output.get("byteCount") != os.path.getsize(path):
            raise SystemExit(f"Manifest hash/size mismatch: {filename}")
    capture_camera = os.path.join(directory, "angel_head_v1_camera.json")
    if open(capture_camera, "rb").read() != open(runtime_camera, "rb").read():
        raise SystemExit("Capture camera bytes differ from the bundled runtime camera bytes.")
    if manifest.get("cameraSHA256") != sha256(runtime_camera):
        raise SystemExit("Manifest camera hash differs from runtime camera hash.")
    with open(capture_camera, encoding="utf-8") as handle:
        camera = json.load(handle)
    with open(os.path.join(directory, "angel_head_v1_complete.json"), encoding="utf-8") as handle:
        completion = json.load(handle)
    if completion.get("status") != "complete":
        raise SystemExit("Capture completion marker is not complete.")
    hierarchy = open(os.path.join(directory, "angel_head_v1_scene-hierarchy.txt"), encoding="utf-8").read()
    if "RECOMMENDED_PROJECTION_TARGET" not in hierarchy:
        raise SystemExit("Hierarchy report has no exact recommended target.")
    recommendation = re.search(r"^RECOMMENDED_PROJECTION_TARGET (\S+)", hierarchy, re.MULTILINE)
    if not recommendation:
        raise SystemExit("Hierarchy report has no parseable projection target.")
    target_path = recommendation.group(1)
    semantic = any(token in target_path.lower() for token in ("face", "head", "skin"))
    model = re.search(
        rf"^MODEL path={re.escape(target_path)} .*?boundsMin=SIMD3<Float>\(([^)]+)\) "
        r"boundsMax=SIMD3<Float>\(([^)]+)\)",
        hierarchy,
        re.MULTILINE,
    )
    if not model:
        raise SystemExit("Hierarchy report has no bounds for the selected projection target.")
    minimum = [float(value.strip()) for value in model.group(1).split(",")]
    maximum = [float(value.strip()) for value in model.group(2).split(",")]
    extents = [high - low for low, high in zip(minimum, maximum)]
    head_sized = all(0 < extent <= 0.75 for extent in extents)
    target_minimum = camera.get("targetBoundsMinimumSubjectMeters", [])
    target_maximum = camera.get("targetBoundsMaximumSubjectMeters", [])
    cube_extents = [
        float(high) - float(low)
        for low, high in zip(target_minimum, target_maximum)
    ]
    cube_driven_face_region = (
        camera.get("cameraMathVersion") == "mind-eye-projection-camera-cube-v1"
        and len(cube_extents) == 3
        and all(0 < extent <= 0.75 for extent in cube_extents)
    )
    if not semantic and not head_sized and not cube_driven_face_region:
        raise SystemExit(
            "Capture is structurally valid but is not a face-only projection: "
            f"target {target_path} has full-body extents {extents}."
        )
    print(f"Mind's Eye projection capture validation: PASS ({directory})")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory")
    parser.add_argument("--runtime-camera")
    parser.add_argument("--source-audit-only", action="store_true")
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    if args.source_audit_only:
        source_audit(os.path.realpath(args.repository_root))
        return
    if not args.directory or not args.runtime_camera:
        parser.error("--directory and --runtime-camera are required")
    validate(os.path.realpath(args.directory), os.path.realpath(args.runtime_camera))


if __name__ == "__main__":
    main()
