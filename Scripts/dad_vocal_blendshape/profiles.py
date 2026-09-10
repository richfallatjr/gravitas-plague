from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class CharacterVocalBlendShapeProfile:
    key: str
    display_name: str
    character_id: str
    descriptor_id: str
    source_asset_name: str
    donor_asset_name: str
    source_descriptor_path: str
    runtime_descriptor_name: str
    runtime_offsets_name: str
    validation_report_path: str
    build_directory_name: str
    source_asset_resource_name: str
    blend_shape_name: str
    base_pose: str
    target_pose: str
    skel_root_prim_path: str
    mesh_prim_path: str
    audio_roles: tuple[str, ...]
    donor_blend_shape_name: str | None = None

    @property
    def runtime_descriptor_resource_path(self) -> str:
        return (
            "CharacterLibrary/FacialPerformance/"
            + self.runtime_descriptor_name
        )

    @property
    def runtime_offsets_resource_path(self) -> str:
        return (
            "CharacterLibrary/FacialPerformance/"
            + self.runtime_offsets_name
        )


_ANIMATED_AUDIO_ROLES = ("presence_loop", "damage_hits", "death")


DAD_PROFILE = CharacterVocalBlendShapeProfile(
    key="dad",
    display_name="Dad",
    character_id="dad",
    descriptor_id="dad.infected.vocalBlendShape.v1",
    source_asset_name="dad_biped.usdz",
    donor_asset_name="dad_biped_mouth_closed.usdz",
    source_descriptor_path=(
        "Authoring/DadVocalBlendShape/dad_vocal_close_source.json"
    ),
    runtime_descriptor_name="dad_infected_vocal_blendshape.json",
    runtime_offsets_name="dad_infected_vocal_blendshape_offsets.bin",
    validation_report_path=(
        "Authoring/DadVocalBlendShape/Reports/"
        "dad_vocal_close.validation.json"
    ),
    build_directory_name="dad-vocal-blendshape",
    source_asset_resource_name="dad_biped",
    blend_shape_name="dadVocalClose",
    base_pose="wide",
    target_pose="closedTense",
    skel_root_prim_path="/root/Armature",
    mesh_prim_path="/root/Armature/char1/char1",
    audio_roles=_ANIMATED_AUDIO_ROLES,
)


GRANDMA_PROFILE = CharacterVocalBlendShapeProfile(
    key="grandma",
    display_name="Grandma",
    character_id="grandma",
    descriptor_id="grandma.infected.vocalBlendShape.v1",
    source_asset_name="grandma_biped.usdz",
    donor_asset_name="grandma_biped_mouth_closed.usdz",
    source_descriptor_path=(
        "Authoring/GrandmaVocalBlendShape/grandma_vocal_close_source.json"
    ),
    runtime_descriptor_name="grandma_infected_vocal_blendshape.json",
    runtime_offsets_name="grandma_infected_vocal_blendshape_offsets.bin",
    validation_report_path=(
        "Authoring/GrandmaVocalBlendShape/Reports/"
        "grandma_vocal_close.validation.json"
    ),
    build_directory_name="grandma-vocal-blendshape",
    source_asset_resource_name="grandma_biped",
    blend_shape_name="grandmaVocalClose",
    base_pose="wide",
    target_pose="closedTense",
    skel_root_prim_path="/root/Armature",
    mesh_prim_path="/root/Armature/char1/char1",
    audio_roles=_ANIMATED_AUDIO_ROLES,
    donor_blend_shape_name="Lattice",
)


SPOUSE_PROFILE = CharacterVocalBlendShapeProfile(
    key="spouse",
    display_name="Spouse",
    character_id="spouse",
    descriptor_id="spouse.infected.vocalBlendShape.v1",
    source_asset_name="spouse_biped.usdz",
    donor_asset_name="spouse_biped_mouth_closed.usdz",
    source_descriptor_path=(
        "Authoring/SpouseVocalBlendShape/spouse_vocal_close_source.json"
    ),
    runtime_descriptor_name="spouse_infected_vocal_blendshape.json",
    runtime_offsets_name="spouse_infected_vocal_blendshape_offsets.bin",
    validation_report_path=(
        "Authoring/SpouseVocalBlendShape/Reports/"
        "spouse_vocal_close.validation.json"
    ),
    build_directory_name="spouse-vocal-blendshape",
    source_asset_resource_name="spouse_biped",
    blend_shape_name="spouseVocalClose",
    base_pose="wide",
    target_pose="closedTense",
    skel_root_prim_path="/root/Armature",
    mesh_prim_path="/root/Armature/char1/char1",
    audio_roles=_ANIMATED_AUDIO_ROLES,
    # The owner-supplied Blender donor currently retains this legacy name.
    # Lock it explicitly so the authoring tool never falls back to mesh points.
    donor_blend_shape_name="dadVocalClose",
)


BIKER_PROFILE = CharacterVocalBlendShapeProfile(
    key="biker",
    display_name="Biker",
    character_id="biker",
    descriptor_id="biker.infected.vocalBlendShape.v1",
    source_asset_name="biker_biped.usdz",
    donor_asset_name="biker_biped_mouth_closed.usdz",
    source_descriptor_path=(
        "Authoring/BikerVocalBlendShape/biker_vocal_close_source.json"
    ),
    runtime_descriptor_name="biker_infected_vocal_blendshape.json",
    runtime_offsets_name="biker_infected_vocal_blendshape_offsets.bin",
    validation_report_path=(
        "Authoring/BikerVocalBlendShape/Reports/"
        "biker_vocal_close.validation.json"
    ),
    build_directory_name="biker-vocal-blendshape",
    source_asset_resource_name="biker_biped",
    blend_shape_name="bikerVocalClose",
    base_pose="wide",
    target_pose="closedTense",
    skel_root_prim_path="/root/Armature",
    mesh_prim_path="/root/Armature/char1/char1",
    audio_roles=_ANIMATED_AUDIO_ROLES,
    # The owner-supplied Blender donor stores its sculpt in this shape key.
    # Lock it explicitly so the tool cannot silently use the open mesh points.
    donor_blend_shape_name="Lattice",
)


NEIGHBOR_PROFILE = CharacterVocalBlendShapeProfile(
    key="neighbor",
    display_name="Neighbor",
    character_id="neighbor",
    descriptor_id="neighbor.infected.vocalBlendShape.v1",
    source_asset_name="neighbor_biped.usdz",
    donor_asset_name="neighbor_biped_mouth_closed.usdz",
    source_descriptor_path=(
        "Authoring/NeighborVocalBlendShape/neighbor_vocal_close_source.json"
    ),
    runtime_descriptor_name="neighbor_infected_vocal_blendshape.json",
    runtime_offsets_name="neighbor_infected_vocal_blendshape_offsets.bin",
    validation_report_path=(
        "Authoring/NeighborVocalBlendShape/Reports/"
        "neighbor_vocal_close.validation.json"
    ),
    build_directory_name="neighbor-vocal-blendshape",
    source_asset_resource_name="neighbor_biped",
    blend_shape_name="neighborVocalClose",
    base_pose="wide",
    target_pose="closedTense",
    skel_root_prim_path="/root/Armature",
    mesh_prim_path="/root/Armature/char1/char1",
    audio_roles=_ANIMATED_AUDIO_ROLES,
    # The owner-supplied Blender donor stores its sculpt in this shape key.
    # Lock it explicitly so the tool cannot silently use the open mesh points.
    donor_blend_shape_name="Lattice",
)


PROFILES = {
    profile.key: profile
    for profile in (
        DAD_PROFILE,
        GRANDMA_PROFILE,
        SPOUSE_PROFILE,
        BIKER_PROFILE,
        NEIGHBOR_PROFILE,
    )
}
