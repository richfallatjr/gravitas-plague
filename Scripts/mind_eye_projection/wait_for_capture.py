#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import time


def app_container(udid: str, bundle_id: str) -> str:
    result = subprocess.run(
        ["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--capture-id", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=120)
    parser.add_argument("--copy-to", required=True)
    args = parser.parse_args()
    deadline = time.monotonic() + args.timeout_seconds
    source = None
    marker = None
    while time.monotonic() < deadline:
        try:
            container = app_container(args.udid, args.bundle_id)
        except subprocess.CalledProcessError:
            time.sleep(0.25)
            continue
        source = os.path.join(
            container,
            "Library",
            "Application Support",
            "MindEyeProjectionAuthoring",
            args.capture_id,
        )
        marker = os.path.join(source, f"{args.capture_id}_complete.json")
        if os.path.isfile(marker):
            break
        time.sleep(0.25)
    if not marker or not os.path.isfile(marker):
        raise SystemExit(f"Timed out waiting for projection capture. Last source: {source}")
    with open(marker, encoding="utf-8") as handle:
        completion = json.load(handle)
    if os.path.exists(args.copy_to):
        shutil.rmtree(args.copy_to)
    shutil.copytree(source, args.copy_to)
    if completion.get("status") != "complete":
        raise SystemExit(
            f"Projection authoring failed: {completion.get('failureCode')}: {completion.get('message')}"
        )


if __name__ == "__main__":
    main()
