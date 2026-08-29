from __future__ import annotations

from copy import deepcopy

import pytest

from mind_eye_lipsync.doctor import validate_toolchain_lock, validate_version_pins


VERSIONS = {
    "kalpy": "0.9.0",
    "silero-vad": "6.2.1",
    "onnxruntime": "1.29.0",
    "torch": "2.9.1",
    "torchaudio": "2.9.1",
    "numpy": "2.4.6",
}


def test_exact_version_pins_accept_current_toolchain() -> None:
    validate_version_pins("3.3.9", dict(VERSIONS))


@pytest.mark.parametrize(("mfa", "name", "version"), [
    ("3.4.0", "kalpy", "0.9.0"),
    ("3.3.9", "kalpy", "0.10.0"),
    ("3.3.9", "silero-vad", "6.2.0"),
    ("3.3.9", "onnxruntime", "1.28.0"),
])
def test_wrong_pinned_version_is_rejected(mfa: str, name: str, version: str) -> None:
    versions = dict(VERSIONS)
    versions[name] = version
    with pytest.raises(RuntimeError):
        validate_version_pins(mfa, versions)


@pytest.mark.parametrize("mutation", ["toolchainConfigSHA256", "modelSHA256"])
def test_changed_config_or_model_hash_is_rejected(mutation: str) -> None:
    expected = {
        "toolchainConfigSHA256": "0" * 64,
        "models": {"acoustic": {"sha256": "1" * 64}},
    }
    actual = deepcopy(expected)
    if mutation == "toolchainConfigSHA256":
        actual[mutation] = "f" * 64
    else:
        actual["models"]["acoustic"]["sha256"] = "f" * 64
    with pytest.raises(RuntimeError):
        validate_toolchain_lock(actual, expected)
