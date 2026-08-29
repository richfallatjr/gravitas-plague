from __future__ import annotations

from pathlib import Path
from typing import Any

from .built_bundle_audit import audit_built_app


def audit_archive(repository_root: Path, archive_path: Path) -> dict[str, Any]:
    archive_path = archive_path.resolve()
    app_root = archive_path / "Products/Applications"
    apps = sorted(item for item in app_root.glob("*.app") if item.is_dir()) if app_root.is_dir() else []
    if len(apps) != 1:
        return {
            "schemaVersion": 1,
            "status": "FAIL",
            "archivePath": str(archive_path),
            "errors": [f"expected one archived app, found {len(apps)}"],
        }
    built = audit_built_app(repository_root, apps[0])
    dsym_root = archive_path / "dSYMs"
    dsym_bytes = sum(item.stat().st_size for item in dsym_root.rglob("*") if item.is_file()) if dsym_root.is_dir() else 0
    archive_bytes = sum(item.stat().st_size for item in archive_path.rglob("*") if item.is_file())
    return {
        "schemaVersion": 1,
        "status": built["status"],
        "archivePath": str(archive_path),
        "archiveBytes": archive_bytes,
        "dSYMBytes": dsym_bytes,
        "builtAppAudit": built,
        "errors": built["errors"],
    }
