#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import tempfile


def digest(path: str) -> str:
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--target-descriptor", required=True)
    args = parser.parse_args()
    with open(args.candidate, "rb") as handle:
        candidate_bytes = handle.read()
    camera = json.loads(candidate_bytes)
    with open(args.profile, encoding="utf-8") as handle:
        profile = json.load(handle)
    required = {
        "cameraID": "angel_head_v1.camera",
        "profileID": profile["profileID"],
        "imageWidth": 1728,
        "imageHeight": 1728,
        "sourceCropOrigin": [144, 144],
        "sourceCropSize": [1440, 1440],
        "targetDescriptorSHA256": digest(args.target_descriptor),
    }
    for key, expected in required.items():
        if camera.get(key) != expected:
            raise SystemExit(f"Camera {key} mismatch: {camera.get(key)!r} != {expected!r}")
    for key in ("subjectFromCamera", "clipFromCamera", "clipFromSubject"):
        if len(camera.get(key, [])) != 16:
            raise SystemExit(f"Camera {key} is not a 4x4 matrix.")
    os.makedirs(os.path.dirname(args.target), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".projection-camera-", dir=os.path.dirname(args.target))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(candidate_bytes)
        os.replace(temporary, args.target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    main()
