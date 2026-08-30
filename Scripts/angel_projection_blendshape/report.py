from __future__ import annotations

from pathlib import Path
from typing import Any

from .deterministic_json import write


def serializable_validation(value: dict[str, Any]) -> dict[str, Any]:
    output = {
        key: field for key, field in value.items()
        if key not in {"cameraFraming", "projectionMaskBytes"}
    }
    meshes = []
    for mesh in value["meshes"]:
        item = {
            key: field for key, field in mesh.items()
            if key not in {"sparse", "normalOffsets"}
        }
        item["sparsePointIndices"] = list(mesh["sparse"].indices)
        item["normalOffsets"] = (
            "authored" if mesh.get("normalOffsets") is not None else "unavailable"
        )
        meshes.append(item)
    output["meshes"] = meshes
    return output


def write_validation(reports: Path, validation: dict[str, Any]) -> Path:
    path = reports / "angel_jaw_open_projection.validation.json"
    write(path, serializable_validation(validation))
    return path


def write_build(reports: Path, value: dict[str, Any]) -> Path:
    path = reports / "angel_jaw_open_projection.displacement.json"
    write(path, value)
    return path
