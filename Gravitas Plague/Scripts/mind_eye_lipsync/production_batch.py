from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path
import shutil
from typing import Callable, Sequence

from .compiler import CompileRequest, CompileResult
from .config import AUDIO_ROOT, PROJECT_ROOT, RESOURCES_ROOT
from .hashing import sha256_file
from .preview_svg import render_preview_svg
from .registry import EligibilityRegistry, EligiblePR
from .report import build_report
from .deterministic_json import write_atomic_json
from .validator import validate_manifest_file


class BatchEntryStatus(str, Enum):
    PENDING = "pending"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    REUSED_VALID = "reusedValid"


@dataclass(frozen=True, slots=True)
class ProductionBatchRequest:
    output_directory: Path
    report_directory: Path
    workspace_directory: Path
    expected_count: int
    jobs: int
    collect_errors: bool
    keep_intermediates: bool
    resume_valid: bool


@dataclass(frozen=True, slots=True)
class ProductionBatchEntryResult:
    pr_id: str
    status: BatchEntryStatus
    manifest_path: Path | None
    manifest_sha256: str | None
    report_json_path: Path | None
    report_svg_path: Path | None
    diagnostic_codes: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "prID": self.pr_id,
            "status": self.status.value,
            "manifest": self.manifest_path.as_posix() if self.manifest_path else None,
            "manifestSHA256": self.manifest_sha256,
            "reportJSON": self.report_json_path.as_posix() if self.report_json_path else None,
            "reportSVG": self.report_svg_path.as_posix() if self.report_svg_path else None,
            "diagnosticCodes": list(self.diagnostic_codes),
        }


@dataclass(frozen=True, slots=True)
class ProductionBatchResult:
    requested_count: int
    succeeded_count: int
    failed_count: int
    reused_valid_count: int
    entries: tuple[ProductionBatchEntryResult, ...]
    output_directory: Path
    report_directory: Path

    def to_dict(self) -> dict[str, object]:
        return {
            "status": "PASS" if self.failed_count == 0 and self.succeeded_count == self.requested_count else "FAIL",
            "requested": self.requested_count,
            "succeeded": self.succeeded_count,
            "failed": self.failed_count,
            "reusedValid": self.reused_valid_count,
            "entries": [entry.to_dict() for entry in self.entries],
        }


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def validate_batch_paths(request: ProductionBatchRequest) -> None:
    build_root = (PROJECT_ROOT / ".build" / "mind-eye-lipsync").resolve()
    paths = (
        request.output_directory.resolve(),
        request.report_directory.resolve(),
        request.workspace_directory.resolve(),
    )
    if len(set(paths)) != len(paths):
        raise ValueError("Batch output, report, and workspace directories must be distinct")
    for path in paths:
        if not _is_within(path, build_root):
            raise ValueError(f"Phase 7 staging must remain under {build_root}: {path}")
    for path in paths:
        if _is_within(path, AUDIO_ROOT) or _is_within(path, RESOURCES_ROOT / "Turing" / "MindsEye" / "Vignettes"):
            raise ValueError(f"Unsafe Phase 7 staging path: {path}")


def _reuse_entry(entry: EligiblePR, manifest_path: Path, report_json: Path, report_svg: Path) -> ProductionBatchEntryResult | None:
    if not manifest_path.is_file():
        return None
    try:
        payload = validate_manifest_file(manifest_path, verify_sources=True)
        if payload["prID"] != entry.pr_id:
            return None
        manifest_hash = sha256_file(manifest_path)
        write_atomic_json(report_json, build_report(payload, manifest_sha256=manifest_hash))
        report_svg.parent.mkdir(parents=True, exist_ok=True)
        report_svg.write_text(render_preview_svg(payload), encoding="utf-8")
        return ProductionBatchEntryResult(
            pr_id=entry.pr_id,
            status=BatchEntryStatus.REUSED_VALID,
            manifest_path=manifest_path,
            manifest_sha256=manifest_hash,
            report_json_path=report_json,
            report_svg_path=report_svg,
            diagnostic_codes=(),
        )
    except Exception:
        return None


def compile_production_batch(
    *,
    registry: EligibilityRegistry,
    request: ProductionBatchRequest,
    compiler: Callable[[CompileRequest], CompileResult],
    toolchain_root: Path,
) -> ProductionBatchResult:
    if request.expected_count != 37:
        raise ValueError("Phase 7 requires expected_count == 37.")
    if request.jobs != 1:
        raise ValueError("Phase 7 production mode requires jobs == 1.")
    if len(registry.entries) != 37:
        raise ValueError("Registry does not contain 37 entries.")
    validate_batch_paths(request)
    for path in (request.output_directory, request.report_directory, request.workspace_directory):
        path.mkdir(parents=True, exist_ok=True)

    results: list[ProductionBatchEntryResult] = []
    for entry in registry.entries:
        manifest_path = request.output_directory / f"{entry.pr_id}.mouthframes.json"
        report_json = request.report_directory / f"{entry.pr_id}.report.json"
        report_svg = request.report_directory / f"{entry.pr_id}.report.svg"
        entry_workspace = request.workspace_directory / entry.pr_id
        if request.resume_valid:
            reused = _reuse_entry(entry, manifest_path, report_json, report_svg)
            if reused is not None:
                results.append(reused)
                continue
        try:
            result = compiler(CompileRequest(
                pr_id=entry.pr_id,
                output=manifest_path,
                toolchain_root=toolchain_root,
                workspace=entry_workspace,
                report_json=report_json,
                report_svg=report_svg,
                keep_intermediates=request.keep_intermediates,
                force=False,
            ))
            payload = validate_manifest_file(manifest_path, verify_sources=True)
            if payload["prID"] != entry.pr_id or not report_json.is_file() or not report_svg.is_file():
                raise ValueError("Compiler did not produce the complete per-entry output set")
            results.append(ProductionBatchEntryResult(
                pr_id=entry.pr_id,
                status=BatchEntryStatus.SUCCEEDED,
                manifest_path=manifest_path,
                manifest_sha256=sha256_file(manifest_path),
                report_json_path=report_json,
                report_svg_path=report_svg,
                diagnostic_codes=tuple(result.warnings),
            ))
        except KeyboardInterrupt:
            raise
        except Exception as error:
            code = getattr(error, "diagnostic_code", type(error).__name__)
            results.append(ProductionBatchEntryResult(
                pr_id=entry.pr_id,
                status=BatchEntryStatus.FAILED,
                manifest_path=manifest_path if manifest_path.exists() else None,
                manifest_sha256=sha256_file(manifest_path) if manifest_path.is_file() else None,
                report_json_path=report_json if report_json.exists() else None,
                report_svg_path=report_svg if report_svg.exists() else None,
                diagnostic_codes=(str(code), str(error)),
            ))
            if not request.collect_errors:
                break
        finally:
            if not request.keep_intermediates and entry_workspace.exists():
                shutil.rmtree(entry_workspace)

    succeeded = sum(entry.status in (BatchEntryStatus.SUCCEEDED, BatchEntryStatus.REUSED_VALID) for entry in results)
    return ProductionBatchResult(
        requested_count=37,
        succeeded_count=succeeded,
        failed_count=sum(entry.status == BatchEntryStatus.FAILED for entry in results),
        reused_valid_count=sum(entry.status == BatchEntryStatus.REUSED_VALID for entry in results),
        entries=tuple(results),
        output_directory=request.output_directory,
        report_directory=request.report_directory,
    )
