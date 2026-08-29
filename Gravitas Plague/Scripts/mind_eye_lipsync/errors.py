from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum


class ExitCode(IntEnum):
    SUCCESS = 0
    VALIDATION_FAILURE = 1
    TOOLCHAIN_FAILURE = 2
    DETERMINISM_FAILURE = 3
    ALIGNMENT_QUALITY_FAILURE = 4
    INTERNAL_ERROR = 5
    COMPLETE_SET_MISMATCH = 6
    PUBLICATION_FAILURE = 7
    BUNDLE_AUDIT_FAILURE = 8
    REVIEW_GATE_FAILURE = 9


@dataclass(frozen=True, slots=True)
class Diagnostic:
    code: str
    message: str
    severity: str
    pr_id: str | None = None
    path: str | None = None


class MindEyeCompilerError(RuntimeError):
    def __init__(self, message: str, *, exit_code: ExitCode, diagnostic_code: str) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.diagnostic_code = diagnostic_code
