#!/usr/bin/env python3
import argparse
import json
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    candidates = []
    for runtime, devices in payload["devices"].items():
        if "xrOS-27" not in runtime and "visionOS-27" not in runtime:
            continue
        for device in devices:
            if device.get("isAvailable") and "Apple Vision Pro" in device.get("name", ""):
                candidates.append((runtime, device))
    if not candidates:
        raise SystemExit("No available visionOS 27 Apple Vision Pro simulator was found.")
    runtime, device = sorted(candidates, key=lambda item: item[1]["udid"])[0]
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(
            {"udid": device["udid"], "name": device["name"], "runtime": runtime},
            handle,
            indent=2,
            sort_keys=True,
        )
        handle.write("\n")


if __name__ == "__main__":
    main()
