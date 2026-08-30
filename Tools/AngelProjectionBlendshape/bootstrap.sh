#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOL_ENV="${REPOSITORY_ROOT}/.tools/angel-projection-blendshape"
WHEELHOUSE="${TOOL_ENV}/wheelhouse"
BOOTSTRAP_REPORT="${TOOL_ENV}/bootstrap.json"

if [[ ! -x "${TOOL_ENV}/bin/python" ]]; then
  python3 -m venv "${TOOL_ENV}"
fi

mkdir -p "${WHEELHOUSE}"

if ! find "${WHEELHOUSE}" -maxdepth 1 -type f \
  -name 'usd_core-26.8-*.whl' -print -quit | grep -q .; then
  "${TOOL_ENV}/bin/python" -m pip download \
    --disable-pip-version-check \
    --only-binary=:all: \
    --no-deps \
    --dest "${WHEELHOUSE}" \
    --requirement "${SCRIPT_DIR}/requirements.lock"
fi

"${TOOL_ENV}/bin/python" -m pip install \
  --disable-pip-version-check \
  --no-index \
  --find-links "${WHEELHOUSE}" \
  --requirement "${SCRIPT_DIR}/requirements.lock"

"${TOOL_ENV}/bin/python" - \
  "${WHEELHOUSE}" \
  "${BOOTSTRAP_REPORT}" <<'PY'
import hashlib
import json
import platform
import sys
from pathlib import Path
from pxr import Usd

wheelhouse = Path(sys.argv[1])
report_path = Path(sys.argv[2])
wheels = sorted(wheelhouse.glob("usd_core-26.8-*.whl"))
if len(wheels) != 1:
    raise SystemExit(f"expected one pinned usd-core wheel, found {len(wheels)}")
wheel = wheels[0]
digest = hashlib.sha256()
with wheel.open("rb") as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)

required_tools = [
    Path("/usr/bin/usdchecker"),
    Path("/usr/bin/usdcat"),
    Path("/usr/bin/usdzip"),
]
missing = [str(path) for path in required_tools if not path.is_file()]
if missing:
    raise SystemExit("missing Apple USD tools: " + ", ".join(missing))

report = {
    "schemaVersion": 1,
    "pythonVersion": sys.version.split()[0],
    "platform": platform.platform(),
    "wheelFilename": wheel.name,
    "wheelSHA256": digest.hexdigest(),
    "openUSDVersion": list(Usd.GetVersion()),
    "usdcheckerPath": str(required_tools[0]),
    "usdcatPath": str(required_tools[1]),
    "usdzipPath": str(required_tools[2]),
}
report_path.write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(json.dumps(report, indent=2, sort_keys=True))
PY
