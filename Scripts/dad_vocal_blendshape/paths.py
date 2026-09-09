from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ToolPaths:
    repository: Path
    base_asset: Path
    donor_asset: Path
    source_descriptor: Path
    runtime_descriptor: Path
    runtime_offsets: Path
    validation_report: Path
    build_root: Path

    @classmethod
    def discover(cls, repository: Path | None = None) -> "ToolPaths":
        root = (repository or Path(__file__).resolve().parents[2]).resolve()
        facial_performance = root / (
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance"
        )
        authoring = root / "Authoring/DadVocalBlendShape"
        return cls(
            repository=root,
            base_asset=root / "dad_biped.usdz",
            donor_asset=root / "dad_biped_mouth_closed.usdz",
            source_descriptor=authoring / "dad_vocal_close_source.json",
            runtime_descriptor=(
                facial_performance / "dad_infected_vocal_blendshape.json"
            ),
            runtime_offsets=(
                facial_performance / "dad_infected_vocal_blendshape_offsets.bin"
            ),
            validation_report=(
                authoring / "Reports/dad_vocal_close.validation.json"
            ),
            build_root=root / ".build/dad-vocal-blendshape",
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
                "missing Dad authoring input: " + ", ".join(map(str, missing))
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
                "missing Dad runtime artifact: " + ", ".join(map(str, missing))
            )
