from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

from Scripts.angel_projection_blendshape.deterministic_json import dumps
from Scripts.angel_projection_blendshape.normals import compatible_normal_offsets
from Scripts.angel_projection_blendshape.offsets import (
    SparseOffsets,
    compute_sparse_offsets,
)
from Scripts.angel_projection_blendshape.package import package_inventory
from Scripts.angel_projection_blendshape.stages import (
    mesh_paths,
    open_stage,
    stage_contract,
)
from Scripts.angel_projection_blendshape.topology import inspect_mesh


EXPECTED_BLEND_SHAPE_NAME = "dadVocalClose"
EXPECTED_BASE_POSE = "wide"
EXPECTED_TARGET_POSE = "closedTense"


@dataclass(frozen=True)
class ResolvedDonorTarget:
    points: tuple[tuple[float, float, float], ...]
    source: str
    blend_shape_prim_path: str | None
    offset_record_count: int
    nonzero_offset_record_count: int


def apply_blend_shape_offsets(
    base_points: Sequence[Iterable[float]],
    offsets: Sequence[Iterable[float]],
    point_indices: Sequence[int] | None,
) -> tuple[tuple[float, float, float], ...]:
    """Resolve a USD blend-shape target into full mesh-point positions."""
    points = [tuple(float(component) for component in point) for point in base_points]
    deltas = [tuple(float(component) for component in offset) for offset in offsets]
    if not points or any(
        len(point) != 3 or not all(math.isfinite(component) for component in point)
        for point in points
    ):
        raise ValueError("Dad donor base points are empty or malformed")
    if not deltas or any(
        len(delta) != 3 or not all(math.isfinite(component) for component in delta)
        for delta in deltas
    ):
        raise ValueError("Dad donor blendshape offsets are empty or malformed")

    if point_indices is None:
        if len(deltas) != len(points):
            raise ValueError("dense Dad donor blendshape offset count differs from points")
        indices = tuple(range(len(points)))
    else:
        indices = tuple(int(index) for index in point_indices)
        if len(indices) != len(deltas):
            raise ValueError("sparse Dad donor blendshape arrays differ in length")
        if len(set(indices)) != len(indices):
            raise ValueError("Dad donor blendshape point indices are duplicated")
        if any(index < 0 or index >= len(points) for index in indices):
            raise ValueError("Dad donor blendshape point index is out of range")

    for index, delta in zip(indices, deltas):
        base = points[index]
        points[index] = (
            base[0] + delta[0],
            base[1] + delta[1],
            base[2] + delta[2],
        )
    return tuple(points)


def _resolve_donor_target(
    stage: Any,
    mesh_path: str,
    blend_shape_name: str,
    base_points: Sequence[Iterable[float]],
    epsilon: float,
) -> ResolvedDonorTarget:
    """Use the owner-authored shape key when the donor exports one.

    A Blender USD export can retain the visible sculpt in a bound shape key
    while leaving ``Mesh.points`` as the wide/open Basis. Falling back to raw
    points remains supported for the original destructive-sculpt workflow.
    """
    from pxr import UsdSkel

    mesh_prim = stage.GetPrimAtPath(mesh_path)
    binding = UsdSkel.BindingAPI(mesh_prim)
    names = [str(name) for name in (binding.GetBlendShapesAttr().Get() or [])]
    targets = list(binding.GetBlendShapeTargetsRel().GetTargets() or [])
    if len(names) != len(targets):
        raise ValueError(f"Dad donor blendshape binding mismatch at {mesh_path}")

    matches = [index for index, name in enumerate(names) if name == blend_shape_name]
    if not matches:
        return ResolvedDonorTarget(
            points=tuple(tuple(float(value) for value in point) for point in base_points),
            source="meshPoints",
            blend_shape_prim_path=None,
            offset_record_count=0,
            nonzero_offset_record_count=0,
        )
    if len(matches) != 1:
        raise ValueError(
            f"Dad donor blendshape {blend_shape_name} is duplicated at {mesh_path}"
        )

    target_path = targets[matches[0]]
    shape = UsdSkel.BlendShape(stage.GetPrimAtPath(target_path))
    if not shape:
        raise ValueError(f"Dad donor blendshape target is invalid: {target_path}")
    offsets = shape.GetOffsetsAttr().Get()
    if offsets is None:
        raise ValueError(f"Dad donor blendshape has no offsets: {target_path}")
    authored_indices = shape.GetPointIndicesAttr().Get()
    point_indices = None if authored_indices is None else tuple(authored_indices)
    points = apply_blend_shape_offsets(base_points, offsets, point_indices)
    nonzero = sum(
        math.sqrt(sum(float(component) ** 2 for component in offset)) > epsilon
        for offset in offsets
    )
    return ResolvedDonorTarget(
        points=points,
        source="boundBlendShape",
        blend_shape_prim_path=target_path.pathString,
        offset_record_count=len(offsets),
        nonzero_offset_record_count=nonzero,
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _plain(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, (str, int, float, bool)):
        return value
    if hasattr(value, "pathString"):
        return value.pathString
    if hasattr(value, "__iter__"):
        return [_plain(item) for item in value]
    return str(value)


def _is_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def load_source_descriptor(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schemaVersion") != 1:
        raise ValueError("unsupported Dad source descriptor schema")
    if value.get("sourceAsset") != "dad_biped.usdz":
        raise ValueError("Dad source asset identity differs from production")
    if value.get("donorAsset") != "dad_biped_mouth_closed.usdz":
        raise ValueError("Dad donor asset identity differs from owner input")
    if value.get("blendShapeName") != EXPECTED_BLEND_SHAPE_NAME:
        raise ValueError("Dad blendshape name must be dadVocalClose")
    if value.get("basePose") != EXPECTED_BASE_POSE:
        raise ValueError("Dad base pose must remain wide")
    if value.get("targetPose") != EXPECTED_TARGET_POSE:
        raise ValueError("Dad target pose must be closedTense")
    if value.get("skelRootPrimPath") != "/root/Armature":
        raise ValueError("Dad SkelRoot path differs from production")
    bindings = value.get("meshBindings")
    if not isinstance(bindings, list) or len(bindings) != 1:
        raise ValueError("Dad authoring requires exactly one mesh binding")
    binding = bindings[0]
    expected_mesh = "/root/Armature/char1/char1"
    if binding != {
        "basePrimPath": expected_mesh,
        "donorPrimPath": expected_mesh,
    }:
        raise ValueError("Dad mesh binding differs from the audited mesh")
    topology = value.get("expectedTopologySHA256")
    if not _is_sha256(topology):
        raise ValueError("Dad expected topology digest is invalid")
    epsilon = value.get("sparseOffsetEpsilonLocalUnits")
    if not isinstance(epsilon, (int, float)) or not math.isfinite(epsilon) or epsilon <= 0:
        raise ValueError("Dad sparse offset epsilon is invalid")
    excluded = value.get("excludedDonorPrimPaths")
    if not isinstance(excluded, list) or not all(
        isinstance(path, str) and path.startswith("/") for path in excluded
    ):
        raise ValueError("Dad donor exclusion list is invalid")
    return value


def _matrix_values(matrix: Any) -> tuple[float, ...]:
    return tuple(
        float(matrix[row][column])
        for row in range(4)
        for column in range(4)
    )


def _matrix_payload(matrix: Any) -> list[list[float]]:
    return [
        [float(matrix[row][column]) for column in range(4)]
        for row in range(4)
    ]


def _matching_world_transform(
    base_stage: Any,
    base_path: str,
    donor_stage: Any,
    donor_path: str,
) -> Any:
    from pxr import UsdGeom

    base = UsdGeom.XformCache().GetLocalToWorldTransform(
        base_stage.GetPrimAtPath(base_path)
    )
    donor = UsdGeom.XformCache().GetLocalToWorldTransform(
        donor_stage.GetPrimAtPath(donor_path)
    )
    maximum_difference = max(
        (
            abs(left - right)
            for left, right in zip(_matrix_values(base), _matrix_values(donor))
        ),
        default=0.0,
    )
    if maximum_difference > 0.000_000_1:
        raise ValueError(
            f"Dad mesh world transform mismatch: {base_path} != {donor_path}"
        )
    return base


def _relationship_targets(prim: Any, name: str) -> list[str]:
    return [
        target.pathString
        for target in prim.GetRelationship(name).GetTargets()
    ]


def _skeleton_contract(stage: Any, mesh_path: str) -> dict[str, Any]:
    mesh_prim = stage.GetPrimAtPath(mesh_path)
    skeleton_targets = _relationship_targets(mesh_prim, "skel:skeleton")
    if len(skeleton_targets) != 1:
        raise ValueError(f"Dad mesh must bind exactly one skeleton: {mesh_path}")
    skeleton_prim = stage.GetPrimAtPath(skeleton_targets[0])
    if not skeleton_prim or skeleton_prim.GetTypeName() != "Skeleton":
        raise ValueError(f"Dad skeleton binding is invalid: {mesh_path}")
    return {
        "meshPrimPath": mesh_path,
        "skeletonPrimPath": skeleton_targets[0],
        "geometryBindTransform": _plain(
            mesh_prim.GetAttribute("primvars:skel:geomBindTransform").Get()
        ),
        "skinningMethod": _plain(
            mesh_prim.GetAttribute("primvars:skel:skinningMethod").Get()
        ),
        "joints": _plain(skeleton_prim.GetAttribute("joints").Get()),
        "bindTransforms": _plain(
            skeleton_prim.GetAttribute("bindTransforms").Get()
        ),
        "restTransforms": _plain(
            skeleton_prim.GetAttribute("restTransforms").Get()
        ),
    }


def _material_binding(stage: Any, mesh_path: str) -> list[str]:
    return _relationship_targets(
        stage.GetPrimAtPath(mesh_path),
        "material:binding",
    )


def _under_any(path: str, roots: Iterable[str]) -> bool:
    return any(path == root or path.startswith(root + "/") for root in roots)


def _compare_deformation_topology(base: Any, donor: Any) -> None:
    """Require stable point correspondence without trusting donor skinning.

    Blender can rename/rewrite armatures and influence arrays during a sculpt
    export. None of that donor metadata is copied into production: the donor is
    used only as a point-position target. Faces, UV registration, local mesh
    transform, and point count must still match exactly.
    """
    base_payload = dict(base.payload)
    donor_payload = dict(donor.payload)
    donor_payload["primPath"] = base_payload["primPath"]
    for key in ("jointIndices", "jointWeights"):
        base_payload.pop(key, None)
        donor_payload.pop(key, None)
    if base_payload != donor_payload:
        changed = sorted(
            key for key in base_payload
            if base_payload.get(key) != donor_payload.get(key)
        )
        raise ValueError("deformation topology mismatch: " + ", ".join(changed))


def _displacement_statistics(values: Iterable[float]) -> dict[str, float]:
    magnitudes = list(values)
    if not magnitudes or not all(math.isfinite(value) for value in magnitudes):
        raise ValueError("Dad world-space displacement is empty or nonfinite")
    return {
        "mean": sum(magnitudes) / len(magnitudes),
        "rms": math.sqrt(
            sum(value * value for value in magnitudes) / len(magnitudes)
        ),
        "maximum": max(magnitudes),
    }


def validate_pair(
    base_asset: Path,
    donor_asset: Path,
    descriptor: dict[str, Any],
) -> dict[str, Any]:
    from pxr import Gf, UsdSkel, UsdGeom

    base_stage = open_stage(base_asset)
    donor_stage = open_stage(donor_asset)
    base_stage_contract = stage_contract(base_stage)
    donor_stage_contract = stage_contract(donor_stage)
    for key in ("metersPerUnit", "upAxis", "defaultPrim"):
        if base_stage_contract[key] != donor_stage_contract[key]:
            raise ValueError(f"Dad stage contract mismatch: {key}")

    skel_root_path = descriptor["skelRootPrimPath"]
    for label, stage in (("base", base_stage), ("donor", donor_stage)):
        skel_root = UsdSkel.Root(stage.GetPrimAtPath(skel_root_path))
        if not skel_root:
            raise ValueError(f"Dad {label} SkelRoot is invalid: {skel_root_path}")

    bindings = descriptor["meshBindings"]
    selected_base = [binding["basePrimPath"] for binding in bindings]
    selected_donor = [binding["donorPrimPath"] for binding in bindings]
    actual_base = mesh_paths(base_stage)
    if sorted(actual_base) != sorted(selected_base):
        raise ValueError(
            "production Dad mesh inventory differs from the exact selection: "
            f"{actual_base}"
        )

    excluded = descriptor["excludedDonorPrimPaths"]
    for path in excluded:
        if base_stage.GetPrimAtPath(path):
            raise ValueError(f"production Dad unexpectedly contains donor debris: {path}")
    unexpected_donor_meshes = [
        path for path in mesh_paths(donor_stage)
        if path not in selected_donor and not _under_any(path, excluded)
    ]
    if unexpected_donor_meshes:
        raise ValueError(
            "Dad donor contains an unclassified mesh: "
            f"{unexpected_donor_meshes}"
        )

    epsilon = float(descriptor["sparseOffsetEpsilonLocalUnits"])
    meters_per_unit = float(base_stage_contract["metersPerUnit"])
    mesh_results = []
    for binding in bindings:
        base_path = binding["basePrimPath"]
        donor_path = binding["donorPrimPath"]
        base = inspect_mesh(base_stage, base_path)
        donor = inspect_mesh(donor_stage, donor_path)
        _compare_deformation_topology(base, donor)
        expected_topology = descriptor["expectedTopologySHA256"]
        if base.topology_sha256 != expected_topology:
            raise ValueError(
                "production Dad topology digest differs from the audited registration"
            )
        world_transform = _matching_world_transform(
            base_stage,
            base_path,
            donor_stage,
            donor_path,
        )
        base_skeleton = _skeleton_contract(base_stage, base_path)
        if not _material_binding(base_stage, base_path):
            raise ValueError("production Dad material binding is missing")

        donor_target = _resolve_donor_target(
            donor_stage,
            donor_path,
            descriptor["blendShapeName"],
            donor.points,
            epsilon,
        )
        sparse: SparseOffsets = compute_sparse_offsets(
            base.points,
            donor_target.points,
            epsilon,
        )
        if not sparse.indices:
            raise ValueError("Dad owner donor contains no meaningful point deltas")

        world_magnitudes = []
        for offset in sparse.values:
            transformed = world_transform.TransformDir(Gf.Vec3d(*offset))
            world_magnitudes.append(transformed.GetLength() * meters_per_unit)
        world = _displacement_statistics(world_magnitudes)
        normal_offsets = None
        if (
            donor_target.source == "meshPoints"
            and base.normal_interpolation == donor.normal_interpolation == "vertex"
        ):
            all_normal_offsets = compatible_normal_offsets(
                base.normals,
                donor.normals,
                len(base.points),
            )
            if all_normal_offsets is not None:
                normal_offsets = tuple(
                    all_normal_offsets[index] for index in sparse.indices
                )

        skeleton_sha = hashlib.sha256(
            dumps(base_skeleton).encode("utf-8")
        ).hexdigest()
        mesh_results.append({
            "basePrimPath": base_path,
            "targetPrimPath": donor_path,
            "donorTargetSource": donor_target.source,
            "donorBlendShapePrimPath": donor_target.blend_shape_prim_path,
            "donorBlendShapeOffsetRecordCount": donor_target.offset_record_count,
            "donorBlendShapeNonzeroOffsetRecordCount": (
                donor_target.nonzero_offset_record_count
            ),
            "pointCount": len(base.points),
            "baseTopologySHA256": base.topology_sha256,
            "donorTopologySHA256": donor.topology_sha256,
            "skeletonContractSHA256": skeleton_sha,
            "changedPointCount": len(sparse.indices),
            "sparseOffsetEpsilonLocalUnits": epsilon,
            "localDisplacement": {
                "mean": sparse.mean_displacement,
                "rms": sparse.rms_displacement,
                "maximum": sparse.maximum_displacement,
            },
            "worldDisplacementMeters": world,
            "localToWorldTransform": _matrix_payload(world_transform),
            "sparse": sparse,
            "normalOffsets": normal_offsets,
        })

    return {
        "baseAssetSHA256": sha256(base_asset),
        "donorAssetSHA256": sha256(donor_asset),
        "basePackageInventory": package_inventory(base_asset),
        "donorPackageInventory": package_inventory(donor_asset),
        "stage": base_stage_contract,
        "donorStage": donor_stage_contract,
        "skelRootPrimPath": skel_root_path,
        "excludedDonorPrimPaths": excluded,
        "meshes": mesh_results,
    }


def validate_authored_asset(
    asset: Path,
    descriptor: dict[str, Any],
    validation: dict[str, Any],
) -> dict[str, Any]:
    from pxr import Sdf, UsdSkel

    stage = open_stage(asset)
    expected_mesh_paths = [
        mesh["basePrimPath"] for mesh in validation["meshes"]
    ]
    if sorted(mesh_paths(stage)) != sorted(expected_mesh_paths):
        raise ValueError("authored Dad production mesh inventory changed")
    for excluded in descriptor["excludedDonorPrimPaths"]:
        if stage.GetPrimAtPath(excluded):
            raise ValueError(f"authored Dad contains donor-only prim: {excluded}")

    authored = []
    for mesh_result in validation["meshes"]:
        mesh_path = mesh_result["basePrimPath"]
        mesh_prim = stage.GetPrimAtPath(mesh_path)
        topology = inspect_mesh(stage, mesh_path)
        if topology.topology_sha256 != mesh_result["baseTopologySHA256"]:
            raise ValueError("authored Dad topology changed")
        binding = UsdSkel.BindingAPI(mesh_prim)
        names = [str(name) for name in (binding.GetBlendShapesAttr().Get() or [])]
        targets = list(binding.GetBlendShapeTargetsRel().GetTargets() or [])
        if len(names) != len(targets):
            raise ValueError("authored Dad blendshape binding count mismatch")
        matches = [
            index for index, name in enumerate(names)
            if name == descriptor["blendShapeName"]
        ]
        if len(matches) != 1:
            raise ValueError("authored Dad target is missing or duplicated")
        target_path = targets[matches[0]]
        expected_path = Sdf.Path(mesh_path).GetParentPath().AppendChild(
            Sdf.Path(mesh_path).name + "_" + descriptor["blendShapeName"]
        )
        if target_path != expected_path:
            raise ValueError("authored Dad target path differs from the contract")
        shape = UsdSkel.BlendShape(stage.GetPrimAtPath(target_path))
        if not shape:
            raise ValueError("authored Dad target is not a UsdSkelBlendShape")
        indices = tuple(int(value) for value in shape.GetPointIndicesAttr().Get())
        offsets = tuple(
            tuple(float(component) for component in value)
            for value in shape.GetOffsetsAttr().Get()
        )
        sparse = mesh_result["sparse"]
        if indices != sparse.indices or len(offsets) != len(sparse.values):
            raise ValueError("authored Dad sparse point records differ from validation")
        maximum_component_error = max(
            (
                abs(actual - expected)
                for actual_value, expected_value in zip(offsets, sparse.values)
                for actual, expected in zip(actual_value, expected_value)
            ),
            default=0.0,
        )
        if maximum_component_error > 0.000_001:
            raise ValueError("authored Dad offsets differ from the owner donor")
        if any(
            not all(math.isfinite(component) for component in offset)
            or sum(component * component for component in offset) <= 0
            for offset in offsets
        ):
            raise ValueError("authored Dad contains zero or nonfinite offsets")
        authored.append({
            "meshPrimPath": mesh_path,
            "blendShapePrimPath": target_path.pathString,
            "blendShapeName": descriptor["blendShapeName"],
            "sparsePointIndexCount": len(indices),
            "maximumOffsetComponentError": maximum_component_error,
            "nonzeroOffsets": True,
        })

    inventory = package_inventory(asset)
    donor_name = descriptor["donorAsset"]
    if donor_name in inventory or any(donor_name in item for item in inventory):
        raise ValueError("the complete Dad donor was embedded in production")
    return {
        "assetSHA256": sha256(asset),
        "assetBytes": asset.stat().st_size,
        "packageInventory": inventory,
        "donorPackageEmbedded": False,
        "excludedDonorPrimPathsAbsent": list(
            descriptor["excludedDonorPrimPaths"]
        ),
        "authored": authored,
    }


def serializable_validation(value: dict[str, Any]) -> dict[str, Any]:
    output = dict(value)
    meshes = []
    for mesh in value["meshes"]:
        item = {
            key: field
            for key, field in mesh.items()
            if key not in {"sparse", "normalOffsets"}
        }
        item["sparsePointIndices"] = list(mesh["sparse"].indices)
        item["normalOffsets"] = (
            "authored" if mesh.get("normalOffsets") is not None else "unavailable"
        )
        meshes.append(item)
    output["meshes"] = meshes
    return output
