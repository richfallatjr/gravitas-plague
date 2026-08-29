from __future__ import annotations

import json
from pathlib import Path

import pytest

from mind_eye_lipsync.config import CONFIG_ROOT, load_compiler_configuration


def _configuration() -> dict:
    return json.loads((CONFIG_ROOT / "compiler_config.json").read_text(encoding="utf-8"))


def test_all_committed_numeric_configuration_is_finite_and_valid() -> None:
    load_compiler_configuration()


@pytest.mark.parametrize(("section", "key"), [
    ("vad", "minSpeechDurationMs"),
    ("alignment", "beam"),
    ("adjudication", "maximumPhoneDurationSeconds"),
    ("deterministicJSON", "floatDecimalPlaces"),
])
def test_nonfinite_numeric_configuration_is_rejected(
    tmp_path: Path,
    section: str,
    key: str,
) -> None:
    payload = _configuration()
    payload[section][key] = float("nan")
    path = tmp_path / "compiler_config.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    with pytest.raises(ValueError):
        load_compiler_configuration(path)
