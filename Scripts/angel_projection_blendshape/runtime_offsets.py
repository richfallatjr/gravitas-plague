from __future__ import annotations

import hashlib
import struct
from pathlib import Path
from typing import Any

from .stages import open_stage


MAGIC = b"GRJAWP1\0"
SCHEMA_VERSION = 1


def write_runtime_offsets(
    base_asset: Path,
    validation: dict[str, Any],
    output: Path,
) -> dict[str, Any]:
    stage = open_stage(base_asset)
    body = bytearray()
    body += MAGIC
    body += struct.pack("<II", SCHEMA_VERSION, len(validation["meshes"]))
    total_records = 0
    for mesh_result in validation["meshes"]:
        prim_path = mesh_result["basePrimPath"].encode("utf-8")
        points = stage.GetPrimAtPath(mesh_result["basePrimPath"]).GetAttribute(
            "points"
        ).Get()
        sparse = mesh_result["sparse"]
        if len(points) != mesh_result["pointCount"]:
            raise ValueError("runtime offset source point count changed")
        if len(sparse.indices) != len(sparse.values):
            raise ValueError("runtime sparse offset arrays differ in length")
        body += struct.pack(
            "<IIII",
            len(prim_path),
            len(points),
            len(sparse.indices),
            0,
        )
        body += prim_path
        previous = -1
        for index, offset in zip(sparse.indices, sparse.values):
            if index <= previous or index >= len(points):
                raise ValueError("runtime sparse indices are invalid")
            previous = index
            base = points[index]
            body += struct.pack(
                "<Iffffff",
                index,
                float(base[0]),
                float(base[1]),
                float(base[2]),
                float(offset[0]),
                float(offset[1]),
                float(offset[2]),
            )
        total_records += len(sparse.indices)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_bytes(body)
    temporary.replace(output)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "meshCount": len(validation["meshes"]),
        "recordCount": total_records,
        "byteCount": len(body),
        "SHA256": hashlib.sha256(body).hexdigest(),
    }
