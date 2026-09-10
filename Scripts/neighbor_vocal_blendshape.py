#!/usr/bin/env python3
from pathlib import Path
import sys


# Keep imports stable whether this entry point is invoked from the repository
# root or by absolute path from the build wrapper.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from Scripts.dad_vocal_blendshape.cli import main


if __name__ == "__main__":
    raise SystemExit(main(default_character="neighbor"))
