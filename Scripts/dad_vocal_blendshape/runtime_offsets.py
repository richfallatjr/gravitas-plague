from __future__ import annotations

import hashlib
import math
import struct
from pathlib import Path
from typing import Any

from Scripts.angel_projection_blendshape.stages import open_stage


MAGIC = b"GRDADV1\0"
SCHEMA_VERSION = 1
RECORD = struct.Struct("<Iffffff")


def write_runtime_offsets(
    base_asset: Path,
    validation: dict[str, Any],
    output: Path,
) -> dict[str, Any]:
    stage = open_stage(base_asset)
    body = bytearray(MAGIC)
    body += struct.pack("<II", SCHEMA_VERSION, len(validation["meshes"]))
    total_records = 0
    for mesh_result in validation["meshes"]:
        prim_path = mesh_result["basePrimPath"].encode("utf-8")
        points = stage.GetPrimAtPath(mesh_result["basePrimPath"]).GetAttribute(
            "points"
        ).Get()
        sparse = mesh_result["sparse"]
        if len(points) != mesh_result["pointCount"]:
            raise ValueError("character runtime offset point count changed")
        if len(sparse.indices) != len(sparse.values):
            raise ValueError(
                "character runtime sparse offset arrays differ in length"
            )
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
                raise ValueError("character runtime sparse indices are invalid")
            previous = index
            base = points[index]
            values = (
                float(base[0]),
                float(base[1]),
                float(base[2]),
                float(offset[0]),
                float(offset[1]),
                float(offset[2]),
            )
            if not all(math.isfinite(value) for value in values):
                raise ValueError("character runtime sparse record is nonfinite")
            body += RECORD.pack(index, *values)
        total_records += len(sparse.indices)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_bytes(body)
    temporary.replace(output)
    return _metadata(bytes(body), len(validation["meshes"]), total_records)


def _metadata(data: bytes, mesh_count: int, record_count: int) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "formatMagic": MAGIC[:-1].decode("ascii"),
        "meshCount": mesh_count,
        "recordCount": record_count,
        "byteCount": len(data),
        "SHA256": hashlib.sha256(data).hexdigest(),
    }


def validate_runtime_offsets(
    path: Path,
    base_asset: Path,
    validation: dict[str, Any],
) -> dict[str, Any]:
    data = path.read_bytes()
    view = memoryview(data)
    cursor = 0

    def take(count: int) -> memoryview:
        nonlocal cursor
        if count < 0 or cursor + count > len(view):
            raise ValueError("character runtime offset payload is truncated")
        result = view[cursor:cursor + count]
        cursor += count
        return result

    if bytes(take(8)) != MAGIC:
        raise ValueError("character runtime offset payload magic is invalid")
    schema, mesh_count = struct.unpack("<II", take(8))
    if schema != SCHEMA_VERSION or mesh_count != len(validation["meshes"]):
        raise ValueError("character runtime offset payload header is invalid")

    stage = open_stage(base_asset)
    total_records = 0
    for expected in validation["meshes"]:
        path_length, point_count, record_count, reserved = struct.unpack(
            "<IIII", take(16)
        )
        prim_path = bytes(take(path_length)).decode("utf-8")
        sparse = expected["sparse"]
        if (
            reserved != 0
            or prim_path != expected["basePrimPath"]
            or point_count != expected["pointCount"]
            or record_count != len(sparse.indices)
        ):
            raise ValueError("character runtime offset mesh header is invalid")
        points = stage.GetPrimAtPath(prim_path).GetAttribute("points").Get()
        previous = -1
        for expected_index, expected_offset in zip(
            sparse.indices,
            sparse.values,
        ):
            unpacked = RECORD.unpack(take(RECORD.size))
            index = unpacked[0]
            base = unpacked[1:4]
            offset = unpacked[4:7]
            if index <= previous or index != expected_index:
                raise ValueError("character runtime sparse index order is invalid")
            previous = index
            expected_base = tuple(float(value) for value in points[index])
            maximum_error = max(
                abs(actual - wanted)
                for actual, wanted in zip(
                    base + offset,
                    expected_base + tuple(expected_offset),
                )
            )
            if maximum_error > 0.000_001:
                raise ValueError(
                    "character runtime sparse record differs from validation"
                )
        total_records += record_count
    if cursor != len(view):
        raise ValueError("character runtime offset payload has trailing bytes")
    return _metadata(data, mesh_count, total_records)
