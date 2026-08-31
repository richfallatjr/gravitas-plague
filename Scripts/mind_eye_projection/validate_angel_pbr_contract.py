#!/usr/bin/env python3
"""Regenerate the Angel PBR contract in memory and require byte-level parity."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from extract_angel_pbr_contract import generate_contract


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    args = parser.parse_args()
    expected = generate_contract(args.asset.resolve(), args.target.resolve())
    actual = json.loads(args.contract.read_text(encoding="utf-8"))
    if actual != expected:
        raise SystemExit("PBR binding contract is stale or was hand-edited")
    if actual["unsupportedNondefaultFeatures"]:
        raise SystemExit(
            "unsupported imported PBR features: "
            + ", ".join(actual["unsupportedNondefaultFeatures"])
        )
    print(
        "PASS angel PBR contract "
        f"assetSHA={actual['subjectAssetSHA256']} "
        f"graphVersion={actual['graphVersion']}"
    )


if __name__ == "__main__":
    main()
