"""Generic public API backed by the single fixed-character compiler core."""

from dad_vocal_visemes.compiler import (
    ANGEL_GOLDEN_RUNS_SHA256,
    FACIAL_ROOT,
    MANIFEST_FOLDERS,
    POSES,
    SUPPORTED_CHARACTER_IDS,
    FixedCharacterConfiguration,
    FixedCharacterVocalInput,
    configuration_for,
    discover_character_inputs,
    golden_angel,
    inspect_character,
    inspect_characters,
    validate_character_outputs,
    validate_characters,
    write_character,
    write_characters,
)

__all__ = [
    "ANGEL_GOLDEN_RUNS_SHA256",
    "FACIAL_ROOT",
    "MANIFEST_FOLDERS",
    "POSES",
    "SUPPORTED_CHARACTER_IDS",
    "FixedCharacterConfiguration",
    "FixedCharacterVocalInput",
    "configuration_for",
    "discover_character_inputs",
    "golden_angel",
    "inspect_character",
    "inspect_characters",
    "validate_character_outputs",
    "validate_characters",
    "write_character",
    "write_characters",
]
