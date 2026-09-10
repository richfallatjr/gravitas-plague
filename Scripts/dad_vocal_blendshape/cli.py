from __future__ import annotations

import argparse
import json
import math
import platform
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from Scripts.angel_projection_blendshape.deterministic_json import write
from Scripts.angel_projection_blendshape.package import (
    atomically_install,
    build_staged_package,
)
from Scripts.dad_vocal_blendshape.paths import ToolPaths
from Scripts.dad_vocal_blendshape.profiles import DAD_PROFILE, PROFILES
from Scripts.dad_vocal_blendshape.report import write_validation_report
from Scripts.dad_vocal_blendshape.runtime_offsets import (
    validate_runtime_offsets,
    write_runtime_offsets,
)
from Scripts.dad_vocal_blendshape.validation import (
    load_source_descriptor,
    serializable_validation,
    sha256,
    validate_authored_asset,
    validate_pair,
)


LOCKED_POSE_WEIGHTS = {
    "rest": 1.0,
    "small": 0.5,
    "wide": 0.0,
    "round": 0.5,
    "teeth": 1.0,
}
LOCKED_AUDIO_ROLES = list(DAD_PROFILE.audio_roles)
LOCKED_RESPONSE = {
    "increasingWeightHalfLifeSeconds": 0.05,
    "decreasingWeightHalfLifeSeconds": 0.03,
    "crossingHalfLifeSeconds": 0.035,
    "maximumDeltaTimeSeconds": 0.05,
    "assignmentEpsilon": 0.0005,
}
RUNTIME_PAYLOAD_RESOURCE_PATH = (
    DAD_PROFILE.runtime_offsets_resource_path
)


def _runtime_descriptor(
    asset_sha: str,
    payload: dict[str, Any],
    profile=DAD_PROFILE,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "descriptorID": profile.descriptor_id,
        "characterID": profile.character_id,
        "sourceAssetResourceName": profile.source_asset_resource_name,
        "sourceAssetExtension": "usdz",
        "sourceAssetSHA256": asset_sha,
        "blendShapeName": profile.blend_shape_name,
        "basePose": profile.base_pose,
        "poseWeights": LOCKED_POSE_WEIGHTS,
        "fallbackWeight": 1.0,
        "allowedWeightRange": [0.0, 1.0],
        "audioRoles": list(profile.audio_roles),
        "response": LOCKED_RESPONSE,
        "offsetPayloadResourcePath": profile.runtime_offsets_resource_path,
        "offsetPayloadSHA256": payload["SHA256"],
        "offsetPayloadMeshCount": payload["meshCount"],
        "offsetPayloadRecordCount": payload["recordCount"],
    }


def _valid_sha(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def validate_runtime_descriptor(
    value: dict[str, Any],
    asset_sha: str,
    payload: dict[str, Any],
    profile=DAD_PROFILE,
) -> None:
    identity = {
        "schemaVersion": 1,
        "descriptorID": profile.descriptor_id,
        "characterID": profile.character_id,
        "sourceAssetResourceName": profile.source_asset_resource_name,
        "sourceAssetExtension": "usdz",
        "sourceAssetSHA256": asset_sha,
        "blendShapeName": profile.blend_shape_name,
        "basePose": profile.base_pose,
        "poseWeights": LOCKED_POSE_WEIGHTS,
        "fallbackWeight": 1.0,
        "allowedWeightRange": [0.0, 1.0],
        "audioRoles": list(profile.audio_roles),
        "response": LOCKED_RESPONSE,
        "offsetPayloadResourcePath": profile.runtime_offsets_resource_path,
        "offsetPayloadSHA256": payload["SHA256"],
        "offsetPayloadMeshCount": payload["meshCount"],
        "offsetPayloadRecordCount": payload["recordCount"],
    }
    if value != identity:
        changed = sorted(
            key for key in set(value) | set(identity)
            if value.get(key) != identity.get(key)
        )
        raise ValueError(
            f"{profile.display_name} runtime descriptor differs from the "
            "locked contract: "
            + ", ".join(changed)
        )
    if not _valid_sha(value["sourceAssetSHA256"]) or not _valid_sha(
        value["offsetPayloadSHA256"]
    ):
        raise ValueError(
            f"{profile.display_name} runtime descriptor contains an invalid digest"
        )
    response_values = value["response"].values()
    if not all(
        isinstance(number, (int, float))
        and math.isfinite(number)
        and number > 0
        for number in response_values
    ):
        raise ValueError(
            f"{profile.display_name} runtime response contains an invalid value"
        )


def doctor(paths: ToolPaths) -> int:
    from pxr import Usd

    paths.require_authoring_inputs()
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
        "baseAssetSHA256": sha256(paths.base_asset),
        "donorAsset": str(paths.donor_asset),
        "donorAssetSHA256": sha256(paths.donor_asset),
    }, indent=2, sort_keys=True))
    return 0


def validated(paths: ToolPaths) -> tuple[dict[str, Any], dict[str, Any]]:
    paths.require_authoring_inputs()
    source = load_source_descriptor(paths.source_descriptor, paths.profile)
    validation = validate_pair(paths.base_asset, paths.donor_asset, source)
    return source, validation


def validate_donor(paths: ToolPaths) -> int:
    _, validation = validated(paths)
    print(json.dumps(
        serializable_validation(validation),
        indent=2,
        sort_keys=True,
    ))
    return 0


def build(paths: ToolPaths) -> int:
    source, validation = validated(paths)
    paths.build_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="build-", dir=paths.build_root) as raw:
        staging = Path(raw)
        staged_asset = staging / paths.base_asset.name
        package_result = build_staged_package(
            paths.base_asset,
            validation,
            source["blendShapeName"],
            staged_asset,
        )
        authored = validate_authored_asset(staged_asset, source, validation)

        staged_payload = staging / paths.runtime_offsets.name
        payload = write_runtime_offsets(
            paths.base_asset,
            validation,
            staged_payload,
        )
        checked_payload = validate_runtime_offsets(
            staged_payload,
            paths.base_asset,
            validation,
        )
        if checked_payload != payload:
            raise ValueError(
                f"{paths.profile.display_name} runtime payload validation "
                "metadata differs"
            )

        runtime = _runtime_descriptor(
            authored["assetSHA256"],
            payload,
            paths.profile,
        )
        validate_runtime_descriptor(
            runtime,
            authored["assetSHA256"],
            payload,
            paths.profile,
        )
        staged_descriptor = staging / paths.runtime_descriptor.name
        write(staged_descriptor, runtime)

        report = {
            "schemaVersion": 1,
            "status": "PASS",
            "blendShapeName": source["blendShapeName"],
            "direction": {
                "weight0": "production base/default wide mouth",
                "weight0_5": "intermediate small/round mouth",
                "weight1": "owner-authored closed/tense mouth",
            },
            "baseAssetSHA256Before": validation["baseAssetSHA256"],
            "donorAssetSHA256": validation["donorAssetSHA256"],
            "baseAssetSHA256After": authored["assetSHA256"],
            "donorBundled": False,
            "runtimeOffsetRepairRequired": True,
            "validation": serializable_validation(validation),
            "package": package_result,
            "authoredAsset": authored,
            "runtimeOffsetPayload": payload,
            "runtimeDescriptor": {
                "resourcePath": paths.profile.runtime_descriptor_resource_path,
                "SHA256": sha256(staged_descriptor),
                "value": runtime,
            },
            "usdchecker": {
                "path": "/usr/bin/usdchecker",
                "status": "PASS",
            },
        }
        if paths.profile != DAD_PROFILE:
            report["characterID"] = paths.profile.character_id
        staged_report = staging / paths.validation_report.name
        write_validation_report(staged_report, report)

        for destination in (
            paths.runtime_offsets,
            paths.runtime_descriptor,
            paths.validation_report,
        ):
            destination.parent.mkdir(parents=True, exist_ok=True)
        atomically_install(staged_payload, paths.runtime_offsets)
        atomically_install(staged_descriptor, paths.runtime_descriptor)
        atomically_install(staged_report, paths.validation_report)
        atomically_install(staged_asset, paths.base_asset)

    subprocess.run(["/usr/bin/usdchecker", str(paths.base_asset)], check=True)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


def validate_runtime(paths: ToolPaths) -> int:
    paths.require_authoring_inputs()
    paths.require_runtime_outputs()
    source, validation = validated(paths)
    authored = validate_authored_asset(paths.base_asset, source, validation)
    payload = validate_runtime_offsets(
        paths.runtime_offsets,
        paths.base_asset,
        validation,
    )
    runtime = json.loads(paths.runtime_descriptor.read_text(encoding="utf-8"))
    validate_runtime_descriptor(
        runtime,
        authored["assetSHA256"],
        payload,
        paths.profile,
    )
    subprocess.run(["/usr/bin/usdchecker", str(paths.base_asset)], check=True)
    print(json.dumps({
        "status": "PASS",
        "assetSHA256": authored["assetSHA256"],
        "blendShapeName": source["blendShapeName"],
        "topologySHA256": validation["meshes"][0]["baseTopologySHA256"],
        "sparsePointIndexCount": validation["meshes"][0]["changedPointCount"],
        "maximumWorldDisplacementMeters": validation["meshes"][0][
            "worldDisplacementMeters"
        ]["maximum"],
        "offsetPayloadSHA256": payload["SHA256"],
        "donorBundled": False,
        "usdchecker": "PASS",
    }, indent=2, sort_keys=True))
    return 0


def main(
    argv: list[str] | None = None,
    default_character: str = "dad",
) -> int:
    if default_character not in PROFILES:
        raise ValueError(f"unknown character profile: {default_character}")
    parser = argparse.ArgumentParser(
        description=(
            f"Author {PROFILES[default_character].display_name}'s "
            "owner-supplied mouth-close blendshape"
        ),
    )
    parser.add_argument(
        "command",
        choices=["doctor", "validate-donor", "build", "validate-runtime"],
    )
    parser.add_argument("--repository", type=Path)
    parser.add_argument(
        "--character",
        choices=sorted(PROFILES),
        default=default_character,
    )
    args = parser.parse_args(argv)
    paths = ToolPaths.discover(
        args.repository,
        profile=PROFILES[args.character],
    )
    commands = {
        "doctor": doctor,
        "validate-donor": validate_donor,
        "build": build,
        "validate-runtime": validate_runtime,
    }
    try:
        return commands[args.command](paths)
    except FileNotFoundError as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2
    except Exception as error:
        print(f"FAIL: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
