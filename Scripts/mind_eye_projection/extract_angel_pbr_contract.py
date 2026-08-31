#!/usr/bin/env python3
"""Extract the exact Angel UsdPreviewSurface texture binding contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path
from typing import Any

try:
    from pxr import Sdf, Usd, UsdGeom, UsdShade
except ImportError as error:  # pragma: no cover - exercised by host invocation
    raise SystemExit(
        "OpenUSD Python is unavailable. Run Tools/AngelProjectionBlendshape/bootstrap.sh "
        "and invoke this script with .tools/angel-projection-blendshape/bin/python."
    ) from error


ROLE_INPUTS = {
    "baseColor": ("diffuseColor", "color", None),
    "metallic": ("metallic", "rawData", "red"),
    "roughness": ("roughness", "rawData", "red"),
    "normal": ("normal", "tangentSpaceNormal", None),
    "emission": ("emissiveColor", "color", None),
}


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def as_floats(value: Any, count: int, default: list[float]) -> list[float]:
    if value is None:
        return default
    try:
        values = list(value)
    except TypeError:
        values = [value]
    values = [float(item) for item in values]
    return (values + default)[:count]


def connected_shader(shader_input: UsdShade.Input) -> tuple[UsdShade.Shader, str]:
    source = shader_input.GetConnectedSource()
    if not source:
        raise RuntimeError(f"{shader_input.GetFullName()} is not texture connected")
    connectable, output_name, _ = source
    shader = UsdShade.Shader(connectable.GetPrim())
    if not shader:
        raise RuntimeError(f"{shader_input.GetFullName()} source is not a shader")
    return shader, str(output_name)


def input_value(shader: UsdShade.Shader, name: str, default: Any) -> Any:
    value_input = shader.GetInput(name)
    value = value_input.Get() if value_input else None
    return default if value is None else value


def texture_member_bytes(asset: Path, packaged_path: str) -> bytes:
    normalized = packaged_path.removeprefix("./")
    with zipfile.ZipFile(asset) as archive:
        candidates = {name.removeprefix("./"): name for name in archive.namelist()}
        if normalized not in candidates:
            raise RuntimeError(f"packaged texture is missing: {packaged_path}")
        return archive.read(candidates[normalized])


def resolve_uv_contract(texture: UsdShade.Shader) -> tuple[str, list[float], list[float], float]:
    st_input = texture.GetInput("st")
    if not st_input:
        raise RuntimeError(f"{texture.GetPath()} has no st input")
    source = st_input.GetConnectedSource()
    if not source:
        raise RuntimeError(f"{texture.GetPath()}.inputs:st is not connected")
    connectable, _, _ = source
    shader = UsdShade.Shader(connectable.GetPrim())
    shader_id = str(shader.GetIdAttr().Get())
    scale = [1.0, 1.0]
    translation = [0.0, 0.0]
    rotation = 0.0
    if shader_id == "UsdTransform2d":
        scale = as_floats(input_value(shader, "scale", None), 2, scale)
        translation = as_floats(input_value(shader, "translation", None), 2, translation)
        rotation = float(input_value(shader, "rotation", 0.0))
        source = shader.GetInput("in").GetConnectedSource()
        if not source:
            raise RuntimeError(f"{shader.GetPath()} has no input primvar")
        shader = UsdShade.Shader(source[0].GetPrim())
        shader_id = str(shader.GetIdAttr().Get())
    if not shader_id.startswith("UsdPrimvarReader_"):
        raise RuntimeError(f"unsupported UV source shader: {shader_id}")
    uv_name = str(input_value(shader, "varname", ""))
    if uv_name != "st":
        raise RuntimeError(f"unsupported UV primvar: {uv_name}")
    return "primvars:st", scale, translation, rotation


def texture_binding(
    asset: Path,
    surface: UsdShade.Shader,
    role: str,
    surface_input_name: str,
    semantic: str,
    expected_scalar: str | None,
) -> dict[str, Any]:
    source_input = surface.GetInput(surface_input_name)
    if not source_input:
        raise RuntimeError(f"surface input is missing: {surface_input_name}")
    texture, output_name = connected_shader(source_input)
    if str(texture.GetIdAttr().Get()) != "UsdUVTexture":
        raise RuntimeError(f"{role} is not driven by UsdUVTexture")
    asset_value = input_value(texture, "file", None)
    source_path = asset_value.path if isinstance(asset_value, Sdf.AssetPath) else str(asset_value)
    if not source_path:
        raise RuntimeError(f"{role} texture file is empty")
    uv_set, transform_scale, transform_translation, transform_rotation = (
        resolve_uv_contract(texture)
    )
    scalar_channels = {"r": "red", "g": "green", "b": "blue", "a": "alpha"}
    scalar_channel = scalar_channels.get(output_name)
    if expected_scalar and scalar_channel != expected_scalar:
        raise RuntimeError(
            f"{role} channel changed: expected {expected_scalar}, found {output_name}"
        )
    return {
        "UVSetIndex": 0,
        "UVSetName": uv_set,
        "bias": as_floats(input_value(texture, "bias", None), 4, [0.0] * 4),
        # RealityKit's imported MaterialParameters.Texture already carries the
        # USD image orientation. Sampling it by the USD st coordinate therefore
        # must not apply ShaderGraph's additional V flip.
        "noFlipV": True,
        "role": role,
        "scalarChannel": scalar_channel,
        "scale": as_floats(input_value(texture, "scale", None), 4, [1.0] * 4),
        "semantic": semantic,
        "sourceAssetPath": source_path.removeprefix("./"),
        "sourceAssetSHA256": sha256_bytes(texture_member_bytes(asset, source_path)),
        "transformRotationDegrees": transform_rotation,
        "transformScale": transform_scale,
        "transformTranslation": transform_translation,
        "wrapS": str(input_value(texture, "wrapS", "repeat")),
        "wrapT": str(input_value(texture, "wrapT", "repeat")),
    }


def resolve_target_prim(stage: Usd.Stage, runtime_path: str) -> Usd.Prim:
    direct = stage.GetPrimAtPath(runtime_path)
    if direct and direct.IsValid():
        return direct
    matches = [
        prim for prim in stage.Traverse()
        if prim.IsA(UsdGeom.Mesh) and runtime_path.endswith(str(prim.GetPath()))
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"target path did not resolve uniquely in USDZ: {runtime_path}; "
            f"matches={[str(item.GetPath()) for item in matches]}"
        )
    return matches[0]


def generate_contract(asset: Path, target_path: Path) -> dict[str, Any]:
    target = json.loads(target_path.read_text(encoding="utf-8"))
    runtime_target_path = target["targetEntityPath"]
    stage = Usd.Stage.Open(str(asset))
    if stage is None:
        raise RuntimeError(f"OpenUSD could not open {asset}")
    prim = resolve_target_prim(stage, runtime_target_path)
    material, _ = UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()
    if not material:
        raise RuntimeError(f"target mesh has no bound material: {prim.GetPath()}")
    surface_result = material.ComputeSurfaceSource()
    surface = surface_result[0] if surface_result else None
    if not surface:
        raise RuntimeError("bound material has no active surface shader")
    surface = UsdShade.Shader(surface.GetPrim())
    surface_id = str(surface.GetIdAttr().Get())
    unsupported: list[str] = []
    if surface_id != "UsdPreviewSurface":
        unsupported.append(f"surfaceShaderID={surface_id}")
    opacity_input = surface.GetInput("opacity")
    opacity = opacity_input.Get() if opacity_input else 1.0
    if opacity_input and opacity_input.HasConnectedSource():
        unsupported.append("textureDrivenOpacity")
    if opacity is not None and abs(float(opacity) - 1.0) > 1e-6:
        unsupported.append(f"opacity={float(opacity)}")
    cutoff = input_value(surface, "opacityThreshold", 0.0)
    if abs(float(cutoff)) > 1e-6:
        unsupported.append(f"opacityThreshold={float(cutoff)}")
    bindings = {
        role: texture_binding(asset, surface, role, *definition)
        for role, definition in ROLE_INPUTS.items()
    }
    double_sided = bool(UsdGeom.Mesh(prim).GetDoubleSidedAttr().Get())
    return {
        "baseColor": bindings["baseColor"],
        "contractID": "angel_head_v1.pbr-binding",
        "emission": bindings["emission"],
        "expectedFaceCulling": "none" if double_sided else "back",
        "expectedOpacityMode": "opaque",
        "graphVersion": "angel-camera-projector-uv-receiver/2",
        "materialIndex": 0,
        "materialNetworkType": "UsdPreviewSurface",
        "metallic": bindings["metallic"],
        "normal": bindings["normal"],
        "roughness": bindings["roughness"],
        "schemaVersion": 1,
        "subjectAssetName": asset.name,
        "subjectAssetSHA256": sha256_path(asset),
        "surfaceShaderID": surface_id,
        "targetEntityPath": runtime_target_path,
        "unsupportedNondefaultFeatures": sorted(unsupported),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    contract = generate_contract(args.asset.resolve(), args.target.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(contract, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(contract, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
