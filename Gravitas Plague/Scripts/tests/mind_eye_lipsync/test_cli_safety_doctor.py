from __future__ import annotations

from argparse import Namespace
from pathlib import Path

import pytest

from mind_eye_lipsync.cli import _compile_all_plan, inventory
from mind_eye_lipsync.compiler import CompileRequest, _validate_output
from mind_eye_lipsync.config import AUDIO_ROOT, PROJECT_ROOT
from mind_eye_lipsync.errors import MindEyeCompilerError


def test_inventory_reconciles_all_locked_sources() -> None:
    result = inventory(verify_descriptors=True, verify_audio=True)
    assert result["eligible"] == 37
    assert result["excluded"] == 8
    assert result["missing"] == [] and result["mismatch"] == []


def test_output_inside_audio_root_is_rejected() -> None:
    source = next(AUDIO_ROOT.glob("*.mp3"))
    request = CompileRequest("x", AUDIO_ROOT / "bad.json", PROJECT_ROOT / ".mind-eye-toolchains")
    with pytest.raises(MindEyeCompilerError):
        _validate_output(request, source)


def test_existing_diagnostic_output_requires_force(tmp_path: Path) -> None:
    source = next(AUDIO_ROOT.glob("*.mp3"))
    report = tmp_path / "report.json"
    report.write_text("{}", encoding="utf-8")
    request = CompileRequest(
        "x",
        tmp_path / "manifest.json",
        PROJECT_ROOT / ".mind-eye-toolchains",
        report_json=report,
    )
    with pytest.raises(MindEyeCompilerError):
        _validate_output(request, source)


def test_compile_all_is_deterministic_phase_six_dry_run(tmp_path: Path) -> None:
    args = Namespace(expected_count=37, jobs=1, output_directory=tmp_path, dry_run=True)
    result = _compile_all_plan(args)
    assert result["planned"] == 37 and result["excluded"] == 8
    assert result["wouldOverwrite"] == 0


def test_compile_all_rejects_parallel_authoring(tmp_path: Path) -> None:
    args = Namespace(expected_count=37, jobs=2, output_directory=tmp_path, dry_run=True)
    with pytest.raises(MindEyeCompilerError):
        _compile_all_plan(args)
