from __future__ import annotations

import argparse
import json
import platform
import sys
import tempfile
from pathlib import Path

from .deterministic_json import write
from .mask import write_projection_mask
from .package import atomically_install, build_staged_package, package_inventory
from .paths import ToolPaths
from .report import serializable_validation, write_build, write_validation
from .stages import mesh_paths, open_stage, stage_contract
from .validation import load_source_descriptor, sha256, validate_pair


def doctor(paths: ToolPaths) -> int:
    from pxr import Usd

    paths.require_base()
    required = ["/usr/bin/usdchecker", "/usr/bin/usdcat", "/usr/bin/usdzip"]
    missing = [path for path in required if not Path(path).is_file()]
    if missing:
        raise FileNotFoundError("missing USD tools: " + ", ".join(missing))
    print(json.dumps({
        "status": "PASS",
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "openUSD": list(Usd.GetVersion()),
        "baseAsset": str(paths.base_asset),
        "baseSHA256": sha256(paths.base_asset),
        "targetPresent": paths.target_asset.is_file(),
        "targetPath": str(paths.target_asset),
    }, indent=2, sort_keys=True))
    return 0


def inspect(paths: ToolPaths) -> int:
    paths.require_base()
    stage = open_stage(paths.base_asset)
    print(json.dumps({
        "asset": str(paths.base_asset),
        "SHA256": sha256(paths.base_asset),
        "stage": stage_contract(stage),
        "meshPaths": mesh_paths(stage),
        "packageInventory": package_inventory(paths.base_asset),
    }, indent=2, sort_keys=True))
    return 0


def validated(paths: ToolPaths) -> tuple[dict, dict]:
    paths.require_base()
    paths.require_target()
    source = load_source_descriptor(paths.source_descriptor)
    result = validate_pair(paths.base_asset, paths.target_asset, source)
    write_validation(paths.reports, result)
    return source, result


def validate_target(paths: ToolPaths) -> int:
    _, result = validated(paths)
    print(json.dumps(serializable_validation(result), indent=2, sort_keys=True))
    return 0


def build(paths: ToolPaths) -> int:
    source, validation = validated(paths)
    paths.build_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="build-", dir=paths.build_root) as raw:
        staged = Path(raw) / "angel_posed_01.usdz"
        package_result = build_staged_package(
            paths.base_asset,
            validation,
            source["blendShapeName"],
            staged,
        )
        staged_sha = sha256(staged)
        runtime = json.loads(paths.runtime_descriptor.read_text(encoding="utf-8"))
        runtime["assetSHA256"] = staged_sha
        atomically_install(staged, paths.base_asset)
        write(paths.runtime_descriptor, runtime)
        projection = write_projection_contracts(
            paths=paths,
            source=source,
            validation=validation,
            subject_asset_sha256=staged_sha,
        )
    build_report = {
        "schemaVersion": 1,
        "blendShapeName": source["blendShapeName"],
        "baseAssetSHA256Before": validation["baseAssetSHA256"],
        "targetAssetSHA256": validation["targetAssetSHA256"],
        "baseAssetSHA256After": sha256(paths.base_asset),
        "targetBundled": False,
        "package": package_result,
        "projection": projection,
    }
    write_build(paths.reports, build_report)
    print(json.dumps(build_report, indent=2, sort_keys=True))
    return 0


def validate_runtime(paths: ToolPaths) -> int:
    paths.require_base()
    runtime = json.loads(paths.runtime_descriptor.read_text(encoding="utf-8"))
    actual = sha256(paths.base_asset)
    if runtime["assetSHA256"] != actual:
        raise ValueError(
            f"runtime descriptor hash mismatch: {runtime['assetSHA256']} != {actual}"
        )
    if runtime["poseWeights"] != {
        "rest": 0.0,
        "small": 0.33,
        "wide": 1.0,
        "round": 0.5,
        "teeth": 0.0,
    }:
        raise ValueError("runtime pose mapping differs from locked contract")
    profile = json.loads(paths.projection_profile.read_text(encoding="utf-8"))
    target = json.loads(
        paths.projection_target_descriptor.read_text(encoding="utf-8")
    )
    camera = json.loads(
        paths.projection_camera_descriptor.read_text(encoding="utf-8")
    )
    expected_mask_path = (
        "Turing/MindsEye/Projection/masks/"
        "angel_head_v1_projection-mask-uv.png"
    )
    if profile.get("projectionMaskResourcePath") != expected_mask_path:
        raise ValueError("projection profile does not reference the packaged UV mask")
    mask_sha = sha256(paths.projection_mask)
    if profile.get("projectionMaskSHA256") != mask_sha:
        raise ValueError("projection mask hash differs from the projection profile")
    if target.get("authoringFramingControl", {}).get("sourceAssetSHA256") != \
            sha256(paths.target_asset):
        raise ValueError("camera framing evidence is stale for the owner package")
    if camera.get("subjectAssetSHA256") != actual:
        raise ValueError("projection camera was generated for a different Angel asset")
    if camera.get("targetDescriptorSHA256") != sha256(
        paths.projection_target_descriptor
    ):
        raise ValueError("projection camera target descriptor hash is stale")
    print(json.dumps({
        "status": "PASS",
        "assetSHA256": actual,
        "blendShapeName": runtime["blendShapeName"],
        "targetBundled": paths.target_asset.name in
            package_inventory(paths.base_asset),
        "cameraMathVersion": camera["cameraMathVersion"],
        "cameraControlPrimPath": target["authoringFramingControl"][
            "controlPrimPath"
        ],
        "projectionMaskSHA256": mask_sha,
    }, indent=2, sort_keys=True))
    return 0


def write_projection_contracts(
    paths: ToolPaths,
    source: dict,
    validation: dict,
    subject_asset_sha256: str,
) -> dict:
    framing = validation["cameraFraming"]
    framing_descriptor = validation["cameraFramingDescriptor"]
    mask = validation["projectionMask"]

    target = json.loads(
        paths.projection_target_descriptor.read_text(encoding="utf-8")
    )
    target["framingEntityPath"] = target["targetEntityPath"]
    target["subjectForwardAxis"] = list(framing.forward)
    target["targetLocalOffsetMeters"] = [0.0, 0.0, 0.0]
    target["authoringFramingControl"] = framing_descriptor
    write(paths.projection_target_descriptor, target)
    target_sha = sha256(paths.projection_target_descriptor)

    write_projection_mask(
        validation["projectionMaskBytes"],
        paths.projection_mask,
    )
    profile = json.loads(paths.projection_profile.read_text(encoding="utf-8"))
    profile["projectionMaskResourcePath"] = (
        "Turing/MindsEye/Projection/masks/"
        "angel_head_v1_projection-mask-uv.png"
    )
    profile["projectionMaskSHA256"] = mask["SHA256"]
    profile["projectionMaskConvention"] = source["projectionMaskConvention"]
    write(paths.projection_profile, profile)

    previous_camera = json.loads(
        paths.projection_camera_descriptor.read_text(encoding="utf-8")
    )
    camera = {
        "schemaVersion": 1,
        "cameraID": "angel_head_v1.camera",
        "profileID": profile["profileID"],
        "imageWidth": profile["sourceWidth"],
        "imageHeight": profile["sourceHeight"],
        "nearMeters": framing.near_meters,
        "farMeters": framing.far_meters,
        "fieldOfViewDegrees": framing.field_of_view_degrees,
        "fieldOfViewOrientation": "vertical",
        "subjectFromCamera": framing.subject_from_camera,
        "clipFromCamera": framing.clip_from_camera,
        "clipFromSubject": framing.clip_from_subject,
        "targetCenterSubjectMeters": list(framing.center),
        "targetBoundsMinimumSubjectMeters": list(framing.bounds_minimum),
        "targetBoundsMaximumSubjectMeters": list(framing.bounds_maximum),
        "framingPadding": framing.framing_padding,
        "sourceCropOrigin": [profile["cropOriginX"], profile["cropOriginY"]],
        "sourceCropSize": [profile["viewportWidth"], profile["viewportHeight"]],
        "sceneDefinitionSHA256": previous_camera["sceneDefinitionSHA256"],
        "subjectAssetSHA256": subject_asset_sha256,
        "targetDescriptorSHA256": target_sha,
        "cameraMathVersion": "mind-eye-projection-camera-cube-v1",
    }
    write(paths.projection_camera_descriptor, camera)
    return {
        "cameraControl": framing_descriptor,
        "cameraDescriptorSHA256": sha256(paths.projection_camera_descriptor),
        "targetDescriptorSHA256": target_sha,
        "projectionMask": mask,
        "projectionMaskResourcePath": profile["projectionMaskResourcePath"],
    }


def capture_poses(paths: ToolPaths) -> int:
    paths.require_target()
    validate_runtime(paths)
    print(
        "The production target is packaged and ready. Run the Xcode authoring "
        "capture pass for weights 0.00, 0.33, 0.50, and 1.00."
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=[
            "doctor",
            "inspect",
            "validate-target",
            "build",
            "validate-runtime",
            "capture-poses",
        ],
    )
    parser.add_argument("--repository", type=Path)
    args = parser.parse_args(argv)
    paths = ToolPaths.discover(args.repository)
    commands = {
        "doctor": doctor,
        "inspect": inspect,
        "validate-target": validate_target,
        "build": build,
        "validate-runtime": validate_runtime,
        "capture-poses": capture_poses,
    }
    try:
        return commands[args.command](paths)
    except FileNotFoundError as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2
    except Exception as error:
        print(f"FAIL: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
