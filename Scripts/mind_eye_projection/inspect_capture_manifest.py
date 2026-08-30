#!/usr/bin/env python3
import argparse
import json


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest")
    args = parser.parse_args()
    with open(args.manifest, encoding="utf-8") as handle:
        payload = json.load(handle)
    summary = {
        "captureID": payload.get("captureID"),
        "cameraSHA256": payload.get("cameraSHA256"),
        "maskCoverageFraction": payload.get("maskCoverageFraction"),
        "maskBoundingBoxPixels": payload.get("maskBoundingBoxPixels"),
        "outputs": [item.get("filename") for item in payload.get("outputs", [])],
    }
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
