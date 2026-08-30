#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from chapter03_angel_visemes.compiler import DEFAULT_DESCRIPTOR, DEFAULT_OUTPUT, build, validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Compile the Chapter 3 Angel viseme track")
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build")
    build_parser.add_argument("--descriptor", type=Path, default=DEFAULT_DESCRIPTOR)
    build_parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    build_parser.add_argument("--review-json", type=Path)
    build_parser.add_argument("--review-svg", type=Path)
    build_parser.add_argument("--force", action="store_true")
    validate_parser = commands.add_parser("validate")
    validate_parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    validate_parser.add_argument("--verify-sources", action="store_true")
    arguments = parser.parse_args()
    if arguments.command == "build":
        manifest = build(
            arguments.descriptor,
            arguments.output,
            arguments.review_json,
            arguments.review_svg,
            arguments.force,
        )
        print(f"PASS built {manifest['trackID']} frames={manifest['timeline']['frameCount']}")
    else:
        manifest = validate(arguments.output, arguments.verify_sources)
        print(f"PASS validated {manifest['trackID']} runs={len(manifest['runs'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
