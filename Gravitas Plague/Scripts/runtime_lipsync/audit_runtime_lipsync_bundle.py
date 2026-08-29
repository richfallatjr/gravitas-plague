#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    arguments = parser.parse_args()
    bundle = arguments.bundle.resolve()
    files = [path for path in bundle.rglob("*") if path.is_file()]
    names = Counter(path.name for path in files)
    forbidden = [
        str(path) for path in files
        if path.name == "en-us.lm.bin"
        or path.suffix.lower() in {".py", ".raw"}
        or "pocketsphinx/source" in path.as_posix().lower()
    ]
    expected = {
        "mdef": 1,
        "cmudict-en-us.dict": 1,
        "en-us-phone.lm.bin": 1,
    }
    errors = list(forbidden)
    for name, count in expected.items():
        if names[name] != count:
            errors.append(f"{name} count={names[name]} expected={count}")
    print(json.dumps({
        "status": "FAIL" if errors else "PASS",
        "bundle": str(bundle),
        "errors": errors,
    }, indent=2, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
