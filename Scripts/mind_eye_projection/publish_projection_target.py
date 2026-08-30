#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import tempfile


def has_facial_semantics(payload):
    values = [payload.get("targetEntityPath", ""), payload.get("framingEntityPath") or ""]
    for material in payload.get("materials", []):
        values.append(material.get("entityPath", ""))
        values.extend(material.get("expectedMaterialNames", []))
    return any(any(token in str(value).lower() for token in ("face", "head", "skin")) for value in values)


def hierarchy_extents(hierarchy, target_path):
    for line in hierarchy.splitlines():
        if not line.startswith(f"MODEL path={target_path} "):
            continue
        match = re.search(
            r"boundsMin=SIMD3<Float>\(([^)]+)\) boundsMax=SIMD3<Float>\(([^)]+)\)",
            line,
        )
        if not match:
            break
        minimum = [float(value.strip()) for value in match.group(1).split(",")]
        maximum = [float(value.strip()) for value in match.group(2).split(",")]
        return [high - low for low, high in zip(minimum, maximum)]
    raise SystemExit("Hierarchy report does not contain bounds for the selected target entity.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--hierarchy", required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    with open(args.candidate, encoding="utf-8") as handle:
        payload = json.load(handle)
    encoded = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if "<" in encoded or payload.get("requiredTargetMaterialCount", 0) < 1:
        raise SystemExit("Target candidate contains a placeholder or no selected material.")
    if not payload.get("targetEntityPath") or not payload.get("materials"):
        raise SystemExit("Target candidate has no exact entity/material selection.")
    with open(args.hierarchy, encoding="utf-8") as handle:
        hierarchy = handle.read()
    extents = hierarchy_extents(hierarchy, payload["targetEntityPath"])
    head_sized = all(0 < extent <= 0.75 for extent in extents)
    if not has_facial_semantics(payload) and not head_sized:
        raise SystemExit(
            "BLOCKED: angel_posed_01.usdz exposes no face/head projection target. "
            f"Selected {payload['targetEntityPath']} has full-body extents {extents}. "
            "Author a named face/head/skin entity or material slot (or a separate head-sized framing entity). "
            "The runtime target was not overwritten."
        )
    os.makedirs(os.path.dirname(args.target), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".projection-target-", dir=os.path.dirname(args.target))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(encoded)
        os.replace(temporary, args.target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    main()
