from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from Scripts.dad_vocal_blendshape.profiles import (
    DAD_PROFILE,
    CharacterVocalBlendShapeProfile,
)


@dataclass(frozen=True)
class ToolPaths:
    profile: CharacterVocalBlendShapeProfile
    repository: Path
    base_asset: Path
    donor_asset: Path
    source_descriptor: Path
    runtime_descriptor: Path
    runtime_offsets: Path
    validation_report: Path
    build_root: Path

    @classmethod
    def discover(
        cls,
        repository: Path | None = None,
        profile: CharacterVocalBlendShapeProfile = DAD_PROFILE,
    ) -> "ToolPaths":
        root = (repository or Path(__file__).resolve().parents[2]).resolve()
        facial_performance = root / (
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance"
        )
        return cls(
            profile=profile,
            repository=root,
            base_asset=root / profile.source_asset_name,
            donor_asset=root / profile.donor_asset_name,
            source_descriptor=root / profile.source_descriptor_path,
            runtime_descriptor=facial_performance / profile.runtime_descriptor_name,
            runtime_offsets=facial_performance / profile.runtime_offsets_name,
            validation_report=root / profile.validation_report_path,
            build_root=root / ".build" / profile.build_directory_name,
        )

    def require_authoring_inputs(self) -> None:
        missing = [
            path for path in (
                self.base_asset,
                self.donor_asset,
                self.source_descriptor,
            )
            if not path.is_file()
        ]
        if missing:
            raise FileNotFoundError(
                f"missing {self.profile.display_name} authoring input: "
                + ", ".join(map(str, missing))
            )

    def require_runtime_outputs(self) -> None:
        missing = [
            path for path in (
                self.base_asset,
                self.source_descriptor,
                self.runtime_descriptor,
                self.runtime_offsets,
            )
            if not path.is_file()
        ]
        if missing:
            raise FileNotFoundError(
                f"missing {self.profile.display_name} runtime artifact: "
                + ", ".join(map(str, missing))
            )
