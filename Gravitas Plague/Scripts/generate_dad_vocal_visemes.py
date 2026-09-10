#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json

from dad_vocal_visemes.compiler import golden_angel, inspect, validate_outputs, write


def main() -> int:
    parser = argparse.ArgumentParser(description="Author Dad Angel-grade all-phone visemes")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--golden-angel", action="store_true")
    modes.add_argument("--write", action="store_true")
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--inspect", action="store_true")
    arguments = parser.parse_args()
    if arguments.golden_angel:
        result = golden_angel()
        print(
            "PASS Angel golden "
            f"runsSHA256={result['runsSHA256']} runs={len(result['runs'])}"
        )
    elif arguments.write:
        result = write()
        print(json.dumps({"status": "PASS", **result}, indent=2, sort_keys=True))
    elif arguments.check:
        golden = golden_angel()
        result = validate_outputs()
        print(json.dumps({
            "status": "PASS",
            "angelRunsSHA256": golden["runsSHA256"],
            **result,
        }, indent=2, sort_keys=True))
    else:
        print(json.dumps(inspect(), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

