from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ToolPaths:
    repository: Path
    base_asset: Path
    target_asset: Path
    source_descriptor: Path
    runtime_descriptor: Path
    runtime_offsets: Path
    projection_profile: Path
    projection_target_descriptor: Path
    projection_camera_descriptor: Path
    projection_mask: Path
    reports: Path
    build_root: Path

    @classmethod
    def discover(cls, repository: Path | None = None) -> "ToolPaths":
        root = (repository or Path(__file__).resolve().parents[2]).resolve()
        return cls(
            repository=root,
            base_asset=root / "angel_posed_01.usdz",
            target_asset=root / "angel_posed_mouth_open_blend_01_v0001.usdz",
            source_descriptor=root / (
                "Authoring/AngelProjection/Geometry/"
                "angel_jaw_open_projection_source.json"
            ),
            runtime_descriptor=root / (
                "Gravitas Plague/TuringResources/Turing/Chapter03/"
                "AngelProjection/angel_jaw_open_projection.json"
            ),
            runtime_offsets=root / (
                "Gravitas Plague/TuringResources/Turing/Chapter03/"
                "AngelProjection/angel_jaw_open_projection_offsets.bin"
            ),
            projection_profile=root / (
                "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/"
                "profiles/angel_head_v1.json"
            ),
            projection_target_descriptor=root / (
                "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/"
                "targets/angel_head_v1.target.json"
            ),
            projection_camera_descriptor=root / (
                "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/"
                "cameras/angel_head_v1.camera.json"
            ),
            projection_mask=root / (
                "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/"
                "masks/angel_head_v1_projection-mask-uv.png"
            ),
            reports=root / "Authoring/AngelProjection/Geometry/Reports",
            build_root=root / ".build/angel-projection-blendshape",
        )

    def require_base(self) -> None:
        if not self.base_asset.is_file():
            raise FileNotFoundError(f"production Angel missing: {self.base_asset}")

    def require_target(self) -> None:
        if not self.target_asset.is_file():
            raise FileNotFoundError(
                "owner Angel projection package missing; expected "
                f"{self.target_asset}"
            )
