#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json

from fixed_character_vocal_visemes.compiler import (
    SUPPORTED_CHARACTER_IDS,
    golden_angel,
    inspect_characters,
    validate_characters,
    write_characters,
)


def _selected_characters(values: list[str] | None) -> tuple[str, ...]:
    if not values or values == ["all"]:
        return SUPPORTED_CHARACTER_IDS
    if "all" in values:
        raise ValueError("--character all cannot be combined with named characters")
    if len(set(values)) != len(values):
        raise ValueError("--character values must be unique")
    requested = set(values)
    return tuple(
        character_id
        for character_id in SUPPORTED_CHARACTER_IDS
        if character_id in requested
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Author deterministic Angel-grade all-phone visemes for fixed characters"
        )
    )
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--golden-angel", action="store_true")
    modes.add_argument("--write", action="store_true")
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--inspect", action="store_true")
    parser.add_argument(
        "--character",
        action="append",
        choices=("all", *SUPPORTED_CHARACTER_IDS),
        help="Character to process; repeat for multiple characters (default: all)",
    )
    arguments = parser.parse_args()
    selected = _selected_characters(arguments.character)

    if arguments.golden_angel:
        result = golden_angel()
        print(
            "PASS Angel golden "
            f"runsSHA256={result['runsSHA256']} runs={len(result['runs'])}"
        )
        return 0

    if arguments.write:
        result = write_characters(selected)
    else:
        golden = golden_angel()
        if arguments.check:
            result = {
                "angelRunsSHA256": golden["runsSHA256"],
                **validate_characters(selected),
            }
        else:
            result = {
                "angelRunsSHA256": golden["runsSHA256"],
                **inspect_characters(selected),
            }
    print(json.dumps({"status": "PASS", **result}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
