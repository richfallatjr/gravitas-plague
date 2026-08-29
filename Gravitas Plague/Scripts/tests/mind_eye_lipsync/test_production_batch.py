from pathlib import Path

import pytest

from mind_eye_lipsync.production_batch import ProductionBatchRequest, validate_batch_paths


def test_production_batch_requires_repository_build_containment(tmp_path: Path) -> None:
    request = ProductionBatchRequest(
        output_directory=tmp_path / "manifests",
        report_directory=tmp_path / "reports",
        workspace_directory=tmp_path / "work",
        expected_count=37,
        jobs=1,
        collect_errors=True,
        keep_intermediates=True,
        resume_valid=False,
    )
    with pytest.raises(ValueError, match="staging"):
        validate_batch_paths(request)

