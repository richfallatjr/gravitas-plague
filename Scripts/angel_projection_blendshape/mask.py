from __future__ import annotations

import hashlib
import struct
import zipfile
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def projection_mask_bytes(package: Path, member: str) -> bytes:
    with zipfile.ZipFile(package) as archive:
        try:
            return archive.read(member)
        except KeyError as error:
            raise ValueError(f"projection mask is missing from authoring package: {member}") from error


def validate_projection_mask(data: bytes) -> dict[str, object]:
    if len(data) < 33 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        raise ValueError("projection mask is not a valid PNG")
    width, height, bit_depth, color_type, compression, filtering, interlace = \
        struct.unpack(">IIBBBBB", data[16:29])
    if (width, height, bit_depth, color_type, compression, filtering, interlace) != \
            (1024, 1024, 8, 6, 0, 0, 0):
        raise ValueError(
            "projection mask must be 1024x1024, 8-bit RGBA, non-interlaced; "
            f"found {(width, height, bit_depth, color_type, interlace)}"
        )
    return {
        "width": width,
        "height": height,
        "bitsPerChannel": bit_depth,
        "colorType": "RGBA",
        "SHA256": hashlib.sha256(data).hexdigest(),
        "byteCount": len(data),
    }


def write_projection_mask(data: bytes, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(destination)
