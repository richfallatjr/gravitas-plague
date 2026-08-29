from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import subprocess


@dataclass(frozen=True, slots=True)
class MFAModelPaths:
    acoustic_model: Path
    dictionary: Path
    g2p_model: Path


@dataclass(frozen=True, slots=True)
class MFAExecutionResult:
    output_path: Path
    stdout: str
    stderr: str
    command: tuple[str, ...]
    retry_used: bool


def _invoke(
    arguments: list[str],
    *,
    executable_directory: Path,
    mfa_root_directory: Path,
) -> subprocess.CompletedProcess[bytes]:
    environment = dict(os.environ)
    environment["PATH"] = str(executable_directory) + os.pathsep + environment.get("PATH", "")
    environment["MFA_ROOT_DIR"] = str(mfa_root_directory)
    return subprocess.run(arguments, check=False, capture_output=True, env=environment)


def align_one(
    *,
    mfa: Path,
    analysis_wav: Path,
    transcript_path: Path,
    output_path: Path,
    temporary_directory: Path,
    config_path: Path,
    models: MFAModelPaths,
    mfa_root_directory: Path,
) -> MFAExecutionResult:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_directory.mkdir(parents=True, exist_ok=True)
    base = [
        str(mfa), "align_one", "--config_path", str(config_path),
        "--output_format", "json", "--g2p_model_path", str(models.g2p_model),
        "--temporary_directory", str(temporary_directory), "--num_jobs", "1",
    ]
    positional = [
        str(analysis_wav), str(transcript_path), str(models.dictionary),
        str(models.acoustic_model), str(output_path),
    ]
    first = base + positional
    completed = _invoke(
        first,
        executable_directory=mfa.parent,
        mfa_root_directory=mfa_root_directory,
    )
    retry_used = False
    command = first
    if completed.returncode != 0:
        combined = (completed.stdout + completed.stderr).decode("utf-8", errors="replace")
        if not any(term in combined.lower() for term in ("beam", "retry", "search")):
            raise RuntimeError(f"MFA align_one failed: {combined.strip()}")
        retry_used = True
        command = base + ["--beam", "200", "--retry_beam", "800"] + positional
        completed = _invoke(
            command,
            executable_directory=mfa.parent,
            mfa_root_directory=mfa_root_directory,
        )
    if completed.returncode != 0 or not output_path.is_file() or output_path.stat().st_size == 0:
        combined = (completed.stdout + completed.stderr).decode("utf-8", errors="replace")
        raise RuntimeError(f"MFA align_one failed after bounded retry: {combined.strip()}")
    return MFAExecutionResult(
        output_path=output_path,
        stdout=completed.stdout.decode("utf-8", errors="replace"),
        stderr=completed.stderr.decode("utf-8", errors="replace"),
        command=tuple(command),
        retry_used=retry_used,
    )
