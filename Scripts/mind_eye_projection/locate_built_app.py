#!/usr/bin/env python3
import argparse
import json
import os
import plistlib


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    product = os.path.join(
        os.path.realpath(args.derived_data),
        "Build",
        "Products",
        "Debug-xrsimulator",
        "Gravitas Plague.app",
    )
    plist_path = os.path.join(product, "Info.plist")
    if not os.path.isdir(product) or not os.path.isfile(plist_path):
        raise SystemExit(f"Built app was not found at {product}")
    with open(plist_path, "rb") as handle:
        bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump({"appPath": product, "bundleID": bundle_id}, handle, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
