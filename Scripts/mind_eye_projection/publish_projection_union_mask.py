#!/usr/bin/env python3
"""Retired runtime publisher for the old camera-space union mask.

The 1728/1440 linear union masks remain authoring diagnostics only. Runtime
coverage is exclusively the owner-authored UV receiver mask referenced by the
v2 projection profile.
"""

def main() -> None:
    raise SystemExit(
        "The camera-space union mask is authoring-only and may not be published "
        "into TuringResources. Use the v2 UV receiver-mask contract instead."
    )


if __name__ == "__main__":
    main()
