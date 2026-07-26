#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

RUNNER = Path(
    "Gravitas Plague/Gravitas Plague/Turing/Foundation/"
    "TuringFoundationModelsRunner.swift"
)
FENCE = Path(
    "Gravitas Plague/Gravitas Plague/Turing/Foundation/"
    "TuringFoundationModelsAccessFence.swift"
)
SOURCE_ROOT = Path(
    "Gravitas Plague/Gravitas Plague"
)

SESSION_TOKEN = re.compile(r"\bLanguageModelSession\b")
SESSION_CREATION = re.compile(
    r"(?:FoundationModels\.)?LanguageModelSession\s*(?:\(|\.init\s*\()"
)
DIRECT_RESPOND = re.compile(
    r"\.\s*(?:respond|streamResponse)\s*\("
)


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"ERROR: {message}")


def main() -> None:
    if len(sys.argv) > 2:
        fail(
            "Usage: verify_fresh_foundation_sessions.py [repo-root]"
        )

    repo = (
        Path(sys.argv[1]).expanduser().resolve()
        if len(sys.argv) == 2
        else Path.cwd().resolve()
    )
    source_root = repo / SOURCE_ROOT
    runner = repo / RUNNER
    fence = repo / FENCE

    if not source_root.is_dir():
        fail(f"Missing app source root: {source_root}")
    if not runner.is_file():
        fail(f"Missing fresh-session gateway: {runner}")
    if not fence.is_file():
        fail(f"Missing compile-time access fence: {fence}")

    runner_source = runner.read_text(encoding="utf-8")
    fence_source = fence.read_text(encoding="utf-8")

    local_creation = re.compile(
        r"\blet\s+session\s*=\s*"
        r"FoundationModels\.LanguageModelSession\s*\("
    )
    if len(local_creation.findall(runner_source)) != 1:
        fail(
            "The gateway must contain exactly one local SDK "
            "session-construction site."
        )

    forbidden_runner_storage = (
        "static let session",
        "static var session",
        "private let session",
        "private var session",
        "lazy var session",
    )
    for token in forbidden_runner_storage:
        if token in runner_source:
            fail(
                f"The gateway retains a session through: {token}"
            )

    if (
        "typealias LanguageModelSession" not in fence_source
        or "unavailable" not in fence_source
    ):
        fail("The compile-time direct-session fence is incomplete.")

    violations: list[str] = []

    for path in sorted(source_root.rglob("*.swift")):
        relative = path.relative_to(repo)
        source = path.read_text(
            encoding="utf-8",
            errors="replace",
        )

        if relative == RUNNER:
            continue
        if relative == FENCE:
            if SESSION_CREATION.search(source):
                violations.append(
                    f"{relative}: the fence constructs a session"
                )
            continue

        if SESSION_TOKEN.search(source):
            violations.append(
                f"{relative}: direct LanguageModelSession reference"
            )

        if (
            "import FoundationModels" in source
            and DIRECT_RESPOND.search(source)
        ):
            violations.append(
                f"{relative}: direct Foundation response call"
            )

    if violations:
        fail(
            "All Foundation requests must use the fresh-session "
            "gateway:\n  " + "\n  ".join(violations)
        )

    print(
        "Fresh Foundation session verification passed:\n"
        "  SDK session construction sites: 1\n"
        "  direct session references outside gateway/fence: 0\n"
        "  retained runner sessions: 0"
    )


if __name__ == "__main__":
    main()
