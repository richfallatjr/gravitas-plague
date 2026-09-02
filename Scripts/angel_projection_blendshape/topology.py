from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

from .deterministic_json import dumps


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


@dataclass(frozen=True)
class MeshTopology:
    prim_path: str
    points: Any
    normals: Any
    normal_interpolation: str
    payload: dict[str, Any]
    topology_sha256: str


def inspect_mesh(stage: Any, prim_path: str) -> MeshTopology:
    from pxr import UsdGeom

    prim = stage.GetPrimAtPath(prim_path)
    mesh = UsdGeom.Mesh(prim)
    if not mesh:
        raise ValueError(f"not a UsdGeomMesh: {prim_path}")
    points = mesh.GetPointsAttr().Get()
    if points is None:
        raise ValueError(f"mesh has no default points: {prim_path}")
    face_vertex_indices = _plain(mesh.GetFaceVertexIndicesAttr().Get())
    uv_payload = []
    for primvar in UsdGeom.PrimvarsAPI(prim).GetPrimvars():
        if "st" not in primvar.GetPrimvarName().lower():
            continue
        interpolation = str(primvar.GetInterpolation())
        indices = _plain(primvar.GetIndices())
        values = _plain(primvar.Get())
        # Blender may serialize vertex UVs as indexed face-varying data even
        # when every face-vertex index maps directly back to its mesh vertex.
        # Canonicalize that lossless representation so sculpt-only exports do
        # not fail the topology gate.
        if (
            interpolation == "faceVarying"
            and indices == face_vertex_indices
            and len(values) == len(points)
        ):
            interpolation = "vertex"
            indices = []
        uv_payload.append({
            "name": str(primvar.GetPrimvarName()),
            "interpolation": interpolation,
            "indices": indices,
            "values": values,
        })
    normals = mesh.GetNormalsAttr().Get()
    normal_interpolation = str(mesh.GetNormalsInterpolation())
    local_transform = UsdGeom.Xformable(prim).GetLocalTransformation()
    payload = {
        "primPath": prim_path,
        "pointCount": len(points),
        "faceVertexCounts": _plain(mesh.GetFaceVertexCountsAttr().Get()),
        "faceVertexIndices": face_vertex_indices,
        "orientation": str(mesh.GetOrientationAttr().Get()),
        "subdivisionScheme": str(mesh.GetSubdivisionSchemeAttr().Get()),
        "creaseIndices": _plain(mesh.GetCreaseIndicesAttr().Get()),
        "creaseLengths": _plain(mesh.GetCreaseLengthsAttr().Get()),
        "creaseSharpnesses": _plain(mesh.GetCreaseSharpnessesAttr().Get()),
        "cornerIndices": _plain(mesh.GetCornerIndicesAttr().Get()),
        "cornerSharpnesses": _plain(mesh.GetCornerSharpnessesAttr().Get()),
        "holeIndices": _plain(mesh.GetHoleIndicesAttr().Get()),
        "uvTopology": uv_payload,
        "localTransform": _plain(local_transform),
        "jointIndices": _plain(prim.GetAttribute("primvars:skel:jointIndices").Get()),
        "jointWeights": _plain(prim.GetAttribute("primvars:skel:jointWeights").Get()),
    }
    topology_sha = hashlib.sha256(dumps(payload).encode("utf-8")).hexdigest()
    return MeshTopology(
        prim_path=prim_path,
        points=points,
        normals=normals,
        normal_interpolation=normal_interpolation,
        payload=payload,
        topology_sha256=topology_sha,
    )


def compare(base: MeshTopology, target: MeshTopology) -> None:
    comparable_base = dict(base.payload)
    comparable_target = dict(target.payload)
    comparable_target["primPath"] = comparable_base["primPath"]
    if comparable_base != comparable_target:
        changed = sorted(
            key for key in comparable_base
            if comparable_base.get(key) != comparable_target.get(key)
        )
        raise ValueError("topology mismatch: " + ", ".join(changed))
