from __future__ import annotations

from typing import Any


def author_blend_shapes(
    stage: Any,
    validation: dict[str, Any],
    blend_shape_name: str,
) -> list[dict[str, Any]]:
    from pxr import Sdf, UsdSkel, Vt

    authored = []
    skel_root_path = validation["skelRootPrimPath"]
    skel_root = UsdSkel.Root.Define(stage, skel_root_path)
    if not skel_root:
        raise ValueError(f"could not author SkelRoot at {skel_root_path}")
    for mesh_result in validation["meshes"]:
        mesh_path = Sdf.Path(mesh_result["basePrimPath"])
        mesh_prim = stage.GetPrimAtPath(mesh_path)
        binding = UsdSkel.BindingAPI.Apply(mesh_prim)
        names_attr = binding.CreateBlendShapesAttr()
        targets_rel = binding.CreateBlendShapeTargetsRel()
        names = list(names_attr.Get() or [])
        targets = list(targets_rel.GetTargets() or [])
        if len(names) != len(targets):
            raise ValueError(f"existing blendshape binding mismatch at {mesh_path}")

        target_path = mesh_path.GetParentPath().AppendChild(
            mesh_path.name + "_" + blend_shape_name
        )
        if stage.GetPrimAtPath(target_path):
            stage.RemovePrim(target_path)
        blend_shape = UsdSkel.BlendShape.Define(stage, target_path)
        sparse = mesh_result["sparse"]
        blend_shape.CreateOffsetsAttr().Set(Vt.Vec3fArray(sparse.values))
        blend_shape.CreatePointIndicesAttr().Set(Vt.IntArray(sparse.indices))
        normal_offsets = mesh_result.get("normalOffsets")
        if normal_offsets is not None:
            blend_shape.CreateNormalOffsetsAttr().Set(Vt.Vec3fArray(normal_offsets))

        if blend_shape_name in names:
            index = names.index(blend_shape_name)
            targets[index] = target_path
        else:
            names.append(blend_shape_name)
            targets.append(target_path)
        names_attr.Set(Vt.TokenArray(names))
        targets_rel.SetTargets(targets)
        authored.append({
            "meshPrimPath": mesh_path.pathString,
            "blendShapePrimPath": target_path.pathString,
            "sparsePointIndexCount": len(sparse.indices),
            "normalOffsets": "authored" if normal_offsets is not None else "unavailable",
        })
    stage.GetRootLayer().Save()
    return authored
