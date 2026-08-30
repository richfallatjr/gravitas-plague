from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .camera import resolve_camera_framing
from .mask import projection_mask_bytes, validate_projection_mask
from .offsets import SparseOffsets, compute_sparse_offsets
from .normals import compatible_normal_offsets
from .stages import mesh_paths, open_stage, stage_contract
from .topology import MeshTopology, compare, inspect_mesh


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_source_descriptor(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schemaVersion") != 1:
        raise ValueError("unsupported source descriptor schema")
    if value.get("blendShapeName") != "jawOpenProjection":
        raise ValueError("blendshape name must be jawOpenProjection")
    if not value.get("meshBindings"):
        raise ValueError("meshBindings is empty")
    if not value.get("skelRootPrimPath", "").startswith("/"):
        raise ValueError("skelRootPrimPath must be absolute")
    control = value.get("cameraFramingControl")
    if not isinstance(control, dict) or not control.get("primPath", "").startswith("/"):
        raise ValueError("cameraFramingControl is missing or invalid")
    for key in ("rightLocalAxis", "forwardLocalAxis", "upLocalAxis"):
        if control.get(key) not in {"x", "y", "z", "-x", "-y", "-z"}:
            raise ValueError(f"cameraFramingControl.{key} is invalid")
    if not value.get("projectionMaskPackagePath"):
        raise ValueError("projectionMaskPackagePath is missing")
    if value.get("projectionMaskConvention") != "whiteProjectsBlackSuppresses":
        raise ValueError("projection mask convention differs from the runtime contract")
    return value


def _matrix_values(value: Any) -> tuple[float, ...]:
    return tuple(float(value[row][column]) for row in range(4) for column in range(4))


def _require_matching_world_transforms(
    base_stage: Any,
    base_path: str,
    target_stage: Any,
    target_path: str,
) -> None:
    from pxr import UsdGeom

    base = UsdGeom.XformCache().GetLocalToWorldTransform(
        base_stage.GetPrimAtPath(base_path)
    )
    target = UsdGeom.XformCache().GetLocalToWorldTransform(
        target_stage.GetPrimAtPath(target_path)
    )
    differences = [
        abs(left - right)
        for left, right in zip(_matrix_values(base), _matrix_values(target))
    ]
    if max(differences, default=0) > 0.000_000_1:
        raise ValueError(
            f"mesh world transform mismatch: {base_path} != {target_path}"
        )


def validate_pair(
    base_asset: Path,
    target_asset: Path,
    descriptor: dict[str, Any],
) -> dict[str, Any]:
    base_stage = open_stage(base_asset)
    target_stage = open_stage(target_asset)
    base_contract = stage_contract(base_stage)
    target_contract = stage_contract(target_stage)
    if base_contract["metersPerUnit"] != target_contract["metersPerUnit"]:
        raise ValueError("stage units mismatch")
    if base_contract["upAxis"] != target_contract["upAxis"]:
        raise ValueError("stage up axis mismatch")
    selected_base_paths = [binding["basePrimPath"] for binding in descriptor["meshBindings"]]
    selected_target_paths = [binding["targetPrimPath"] for binding in descriptor["meshBindings"]]
    control_path = descriptor["cameraFramingControl"]["primPath"]
    actual_base_paths = mesh_paths(base_stage)
    actual_target_paths = mesh_paths(target_stage)
    if sorted(actual_base_paths) != sorted(selected_base_paths):
        raise ValueError(
            "production base contains a mesh outside the exact blendshape selection: "
            f"{sorted(set(actual_base_paths) - set(selected_base_paths))}"
        )
    allowed_target_paths = set(selected_target_paths + [control_path])
    if set(actual_target_paths) != allowed_target_paths:
        raise ValueError(
            "authoring package mesh inventory differs from sculpt plus framing cube: "
            f"{actual_target_paths}"
        )
    epsilon = float(descriptor["sparseOffsetEpsilonMeters"])
    maximum_fraction = float(descriptor["maximumDisplacementAsHeadBoundsFraction"])
    mesh_results = []
    for binding in descriptor["meshBindings"]:
        base: MeshTopology = inspect_mesh(base_stage, binding["basePrimPath"])
        target: MeshTopology = inspect_mesh(target_stage, binding["targetPrimPath"])
        compare(base, target)
        _require_matching_world_transforms(
            base_stage,
            binding["basePrimPath"],
            target_stage,
            binding["targetPrimPath"],
        )
        sparse: SparseOffsets = compute_sparse_offsets(
            base.points,
            target.points,
            epsilon,
        )
        normal_offsets = None
        if base.normal_interpolation == target.normal_interpolation == "vertex":
            all_normal_offsets = compatible_normal_offsets(
                base.normals,
                target.normals,
                len(base.points),
            )
            if all_normal_offsets is not None:
                normal_offsets = tuple(
                    all_normal_offsets[index] for index in sparse.indices
                )
        if sparse.maximum_displacement > maximum_fraction:
            raise ValueError(
                "maximum displacement exceeds the conservative stage-meter gate: "
                f"{sparse.maximum_displacement} > {maximum_fraction}"
            )
        mesh_results.append({
            "basePrimPath": binding["basePrimPath"],
            "targetPrimPath": binding["targetPrimPath"],
            "pointCount": len(base.points),
            "baseTopologySHA256": base.topology_sha256,
            "targetTopologySHA256": target.topology_sha256,
            "changedPointCount": len(sparse.indices),
            "meanDisplacementMeters": sparse.mean_displacement,
            "rmsDisplacementMeters": sparse.rms_displacement,
            "maximumDisplacementMeters": sparse.maximum_displacement,
            "sparse": sparse,
            "normalOffsets": normal_offsets,
        })
    framing = resolve_camera_framing(
        target_stage,
        selected_target_paths[0],
        descriptor["cameraFramingControl"],
    )
    mask_data = projection_mask_bytes(
        target_asset,
        descriptor["projectionMaskPackagePath"],
    )
    mask = validate_projection_mask(mask_data)
    target_sha = sha256(target_asset)
    return {
        "baseAssetSHA256": sha256(base_asset),
        "targetAssetSHA256": target_sha,
        "stage": base_contract,
        "targetStage": target_contract,
        "meshes": mesh_results,
        "skelRootPrimPath": descriptor["skelRootPrimPath"],
        "cameraFraming": framing,
        "cameraFramingDescriptor": framing.descriptor_payload(
            target_asset.name,
            target_sha,
        ),
        "projectionMask": mask,
        "projectionMaskBytes": mask_data,
    }
