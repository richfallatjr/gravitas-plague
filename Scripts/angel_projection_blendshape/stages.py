from __future__ import annotations

from pathlib import Path
from typing import Any


def open_stage(path: Path) -> Any:
    from pxr import Usd

    stage = Usd.Stage.Open(str(path))
    if stage is None:
        raise ValueError(f"OpenUSD could not open {path}")
    return stage


def mesh_paths(stage: Any) -> list[str]:
    from pxr import UsdGeom

    return [
        prim.GetPath().pathString
        for prim in stage.Traverse()
        if prim.IsA(UsdGeom.Mesh)
    ]


def stage_contract(stage: Any) -> dict[str, Any]:
    from pxr import Sdf, UsdGeom

    meshes = mesh_paths(stage)
    ancestors: dict[str, list[list[float]]] = {}
    for mesh_path in meshes:
        cursor = Sdf.Path(mesh_path)
        while cursor != Sdf.Path.absoluteRootPath:
            prim = stage.GetPrimAtPath(cursor)
            xformable = UsdGeom.Xformable(prim) if prim else None
            if xformable:
                matrix = xformable.GetLocalTransformation()
                ancestors[cursor.pathString] = [
                    [float(matrix[row][column]) for column in range(4)]
                    for row in range(4)
                ]
            cursor = cursor.GetParentPath()

    return {
        "metersPerUnit": float(UsdGeom.GetStageMetersPerUnit(stage)),
        "upAxis": str(UsdGeom.GetStageUpAxis(stage)),
        "defaultPrim": stage.GetDefaultPrim().GetPath().pathString,
        "meshPaths": meshes,
        "meshAncestorLocalTransforms": ancestors,
    }
