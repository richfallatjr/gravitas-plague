from __future__ import annotations

import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from .authoring import author_blend_shapes
from .stages import open_stage


def package_inventory(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        return sorted(archive.namelist())


def build_staged_package(
    base_asset: Path,
    validation: dict[str, Any],
    blend_shape_name: str,
    output: Path,
) -> dict[str, Any]:
    from pxr import Sdf, UsdUtils

    with tempfile.TemporaryDirectory(prefix="angel-projection-") as raw:
        staging = Path(raw)
        with zipfile.ZipFile(base_asset) as archive:
            archive.extractall(staging)
        root_layers = sorted(
            path for path in staging.iterdir()
            if path.suffix.lower() in {".usd", ".usda", ".usdc"}
        )
        if len(root_layers) != 1:
            raise ValueError(f"expected one USD root layer; found {len(root_layers)}")
        stage = open_stage(root_layers[0])
        authored = author_blend_shapes(stage, validation, blend_shape_name)
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(output.stem + ".tmp" + output.suffix)
        if temporary.exists():
            temporary.unlink()
        result = UsdUtils.CreateNewUsdzPackage(
            Sdf.AssetPath(str(root_layers[0])),
            str(temporary),
        )
        if not result or not temporary.is_file():
            raise RuntimeError("OpenUSD failed to create the staged USDZ")
        subprocess.run(["/usr/bin/usdchecker", str(temporary)], check=True)
        base_non_root = sorted(
            name for name in package_inventory(base_asset)
            if not name.lower().endswith((".usd", ".usda", ".usdc"))
        )
        output_non_root = sorted(
            name for name in package_inventory(temporary)
            if not name.lower().endswith((".usd", ".usda", ".usdc"))
        )
        if base_non_root != output_non_root:
            raise ValueError("production texture/dependency inventory changed")
        temporary.replace(output)
        return {
            "authored": authored,
            "baseInventory": package_inventory(base_asset),
            "outputInventory": package_inventory(output),
            "baseBytes": base_asset.stat().st_size,
            "outputBytes": output.stat().st_size,
        }


def atomically_install(staged: Path, production: Path) -> None:
    temporary = production.with_suffix(production.suffix + ".installing")
    shutil.copy2(staged, temporary)
    temporary.replace(production)
