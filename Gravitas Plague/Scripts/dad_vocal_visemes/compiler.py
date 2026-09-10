from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from typing import Any, Iterable

from chapter03_angel_visemes.compiler import (
    DEFAULT_DESCRIPTOR as ANGEL_DESCRIPTOR,
    DEFAULT_OUTPUT as ANGEL_OUTPUT,
    PHONE_MAP,
    RUNTIME_MODELS,
    TOOLCHAIN_LOCK,
    _compact_runs_hash,
    compile_allphone_viseme_track,
)
from mind_eye_lipsync.constants import REQUIRED_POSES
from mind_eye_lipsync.hashing import deterministic_tree_sha256, sha256_file

from . import COMPILER_VERSION


SCRIPTS_ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = SCRIPTS_ROOT.parent
REPOSITORY_ROOT = PROJECT_DIR.parent
APP_ROOT = PROJECT_DIR / "Gravitas Plague"
CHARACTER_DESCRIPTOR = APP_ROOT / "CharacterLibrary/Characters/dad.character.json"
BLENDSHAPE_DESCRIPTOR = (
    APP_ROOT / "CharacterLibrary/FacialPerformance/dad_infected_vocal_blendshape.json"
)
FACIAL_ROOT = APP_ROOT / "CharacterLibrary/FacialPerformance"
CATALOG_OUTPUT = FACIAL_ROOT / "dad_vocal_viseme_catalog.json"
MANIFEST_OUTPUT_ROOT = FACIAL_ROOT / "DadVisemes"
BUILD_ROOT = REPOSITORY_ROOT / ".build/dad-vocal-visemes"
SOURCE_LOCK = PROJECT_DIR / "ThirdParty/TuringPocketSphinx/SourceLock.json"
RUNTIME_RESOURCE_MANIFEST = (
    PROJECT_DIR / "TuringResources/Turing/RuntimeLipSync/manifest.json"
)
ANGEL_GOLDEN_RUNS_SHA256 = (
    "6a48f84827b2842fb3199c1bf4965113b3a65f8c55eedd7c0b23772c983b4a8a"
)
CATALOG_ID = "dad.infected.vocalVisemes.v1"
CHARACTER_ID = "dad"
POSES = [pose.value for pose in REQUIRED_POSES]
EXPECTED_ROLE_COUNTS = {"presence_loop": 1, "damage_hits": 4, "death": 4}
BLENDSHAPE_DESCRIPTOR_RESOURCE_PATH = (
    "CharacterLibrary/FacialPerformance/dad_infected_vocal_blendshape.json"
)
SUPPORTED_CHARACTER_IDS = ("dad", "grandma", "spouse", "biker", "neighbor")
MANIFEST_FOLDERS = {
    "dad": "DadVisemes",
    "grandma": "GrandmaVisemes",
    "spouse": "SpouseVisemes",
    "biker": "BikerVisemes",
    "neighbor": "NeighborVisemes",
}


@dataclass(frozen=True, slots=True)
class FixedCharacterConfiguration:
    character_id: str
    manifest_folder: str

    @property
    def character_descriptor(self) -> Path:
        return APP_ROOT / f"CharacterLibrary/Characters/{self.character_id}.character.json"

    @property
    def blendshape_descriptor(self) -> Path:
        return (
            FACIAL_ROOT
            / f"{self.character_id}_infected_vocal_blendshape.json"
        )

    @property
    def blendshape_descriptor_resource_path(self) -> str:
        return (
            "CharacterLibrary/FacialPerformance/"
            f"{self.character_id}_infected_vocal_blendshape.json"
        )

    @property
    def catalog_id(self) -> str:
        return f"{self.character_id}.infected.vocalVisemes.v1"

    @property
    def catalog_output(self) -> Path:
        return FACIAL_ROOT / f"{self.character_id}_vocal_viseme_catalog.json"

    @property
    def manifest_output_root(self) -> Path:
        return FACIAL_ROOT / self.manifest_folder


def configuration_for(character_id: str) -> FixedCharacterConfiguration:
    normalized = character_id.casefold()
    if normalized not in SUPPORTED_CHARACTER_IDS:
        raise ValueError(
            f"Unsupported fixed character {character_id!r}; expected one of "
            f"{SUPPORTED_CHARACTER_IDS}"
        )
    return FixedCharacterConfiguration(
        character_id=normalized,
        manifest_folder=MANIFEST_FOLDERS[normalized],
    )


def _configurations_for(
    character_ids: Iterable[str],
) -> tuple[FixedCharacterConfiguration, ...]:
    normalized = tuple(item.casefold() for item in character_ids)
    if not normalized:
        raise ValueError("At least one fixed character must be selected")
    if len(set(normalized)) != len(normalized):
        raise ValueError("Fixed-character selection contains duplicates")
    requested = set(normalized)
    for character_id in requested:
        configuration_for(character_id)
    return tuple(
        configuration_for(character_id)
        for character_id in SUPPORTED_CHARACTER_IDS
        if character_id in requested
    )


@dataclass(frozen=True, slots=True)
class FixedCharacterVocalInput:
    role: str
    audio_file: str
    looping: bool
    source_path: Path
    audio_resource_path: str
    character_id: str = CHARACTER_ID
    manifest_folder: str = MANIFEST_FOLDERS[CHARACTER_ID]

    @property
    def output_name(self) -> str:
        stem = Path(self.audio_file).stem
        if not stem.startswith((f"{self.character_id}-", f"{self.character_id}_")):
            stem = f"{self.character_id}-{stem}"
        return f"{stem}.visemes.json"

    @property
    def manifest_path(self) -> Path:
        return FACIAL_ROOT / self.manifest_folder / self.output_name

    @property
    def manifest_resource_path(self) -> str:
        return (
            f"CharacterLibrary/FacialPerformance/{self.manifest_folder}/"
            + self.output_name
        )

    @property
    def track_id(self) -> str:
        return (
            f"{self.character_id}.{self.role}."
            f"{Path(self.audio_file).stem}.visemes"
        )


def _canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            indent=2,
            separators=(",", ": "),
        )
        + "\n"
    ).encode("utf-8")


def _write_if_changed(path: Path, value: Any) -> bool:
    encoded = _canonical_json_bytes(value)
    if path.is_file() and path.read_bytes() == encoded:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_bytes(encoded)
    temporary.replace(path)
    return True


def _tracked_paths() -> tuple[Path, ...]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
    )
    return tuple(
        (REPOSITORY_ROOT / raw.decode("utf-8")).resolve()
        for raw in result.stdout.split(b"\0")
        if raw
    )


def _resolve_unique_audio(file_name: str, tracked: Iterable[Path]) -> Path:
    matches = [path for path in tracked if path.name == file_name and path.is_file()]
    if len(matches) != 1:
        raise ValueError(
            f"Fixed-character audio {file_name!r} must resolve to one tracked file; found "
            f"{[str(path) for path in matches]}"
        )
    return matches[0]


def _audio_resource_path(path: Path) -> str:
    try:
        return path.relative_to(APP_ROOT).as_posix()
    except ValueError:
        if path.parent == REPOSITORY_ROOT:
            return path.name
        raise ValueError(
            f"Fixed-character audio is outside supported resource roots: {path}"
        )


DadVocalInput = FixedCharacterVocalInput


def discover_character_inputs(
    character_id: str,
) -> tuple[FixedCharacterVocalInput, ...]:
    configuration = configuration_for(character_id)
    descriptor = json.loads(
        configuration.character_descriptor.read_text(encoding="utf-8")
    )
    if descriptor.get("character_id") != configuration.character_id:
        raise ValueError(
            f"{configuration.character_id} character descriptor identity is invalid"
        )
    audio = descriptor.get("audio")
    if not isinstance(audio, dict):
        raise ValueError(
            f"{configuration.character_id} character audio inventory is missing"
        )

    presence = audio.get("presence_loop")
    damage = audio.get("damage_hits")
    death = audio.get("death")
    if not isinstance(presence, dict) or not isinstance(damage, list) or not isinstance(death, list):
        raise ValueError(
            f"{configuration.character_id} presence/damage/death inventory is invalid"
        )
    raw_entries = [
        ("presence_loop", str(presence.get("file", "")), True),
        *(("damage_hits", str(item.get("file", "")), False) for item in damage),
        *(("death", str(item.get("file", "")), False) for item in death),
    ]
    counts = {
        role: sum(1 for candidate, _, _ in raw_entries if candidate == role)
        for role in EXPECTED_ROLE_COUNTS
    }
    if counts != EXPECTED_ROLE_COUNTS or len(raw_entries) != 9:
        raise ValueError(
            f"{configuration.character_id} vocal inventory must be 1/4/4; "
            f"found {counts}"
        )
    if not bool(presence.get("loop")):
        raise ValueError(
            f"{configuration.character_id} presence vocal must remain a loop"
        )
    forbidden = {
        str(item.get("file", ""))
        for key in ("face_hits", "attack")
        for item in audio.get(key, [])
        if isinstance(item, dict)
    }
    names = [name for _, name, _ in raw_entries]
    if any(not name for name in names) or len(set(names)) != 9:
        raise ValueError(
            f"{configuration.character_id} vocal filenames must be nonempty and unique"
        )
    if set(names) & forbidden:
        raise ValueError(
            f"{configuration.character_id} vocal inventory accidentally includes "
            "face-hit or attack audio"
        )

    tracked = _tracked_paths()
    result: list[FixedCharacterVocalInput] = []
    for role, file_name, looping in raw_entries:
        source = _resolve_unique_audio(file_name, tracked)
        result.append(
            FixedCharacterVocalInput(
                role=role,
                audio_file=file_name,
                looping=looping,
                source_path=source,
                audio_resource_path=_audio_resource_path(source),
                character_id=configuration.character_id,
                manifest_folder=configuration.manifest_folder,
            )
        )
    return tuple(result)


def discover_inputs() -> tuple[FixedCharacterVocalInput, ...]:
    """Compatibility entry point for the original Dad-only authoring command."""

    return discover_character_inputs(CHARACTER_ID)


def _alignment_identity() -> dict[str, Any]:
    lock = json.loads(SOURCE_LOCK.read_text(encoding="utf-8"))
    runtime = json.loads(RUNTIME_RESOURCE_MANIFEST.read_text(encoding="utf-8"))
    toolchain = json.loads(TOOLCHAIN_LOCK.read_text(encoding="utf-8"))
    resource_root = RUNTIME_MODELS.parent
    actual_tree = _runtime_resource_tree_sha256(resource_root)
    expected_commit = str(lock["pocketSphinx"]["commit"])
    expected_tree = str(lock["artifacts"]["resourceTreeSHA256"])
    if expected_commit != "511126b492dcb267cf30d49d631946d7b61a9530":
        raise ValueError("PocketSphinx source commit is not the locked 5.1.1 commit")
    if actual_tree != expected_tree or actual_tree != runtime.get("resourceTreeSHA256"):
        raise ValueError("PocketSphinx runtime resource tree is stale")
    return {
        "mode": "pocketsphinxAllPhone",
        "engine": "pocketsphinx",
        "engineVersion": "5.1.1",
        "engineCommit": expected_commit,
        "resourceTreeSHA256": actual_tree,
        "acousticModelSHA256": deterministic_tree_sha256(RUNTIME_MODELS / "acoustic"),
        "phoneLanguageModelSHA256": sha256_file(RUNTIME_MODELS / "en-us-phone.lm.bin"),
        "transcriptSHA256": None,
        "VADModelSHA256": str(toolchain["sileroModelSHA256"]),
        "phonePoseMapSHA256": sha256_file(PHONE_MAP),
        "speechBoundaryPolicy": "pocketsphinxNonSilencePhoneIntervals",
    }


def _runtime_resource_tree_sha256(root: Path) -> str:
    """Match the checked-in PocketSphinx vendor/resource lock contract."""

    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def golden_angel(*, build_root: Path = BUILD_ROOT) -> dict[str, Any]:
    checked = json.loads(ANGEL_OUTPUT.read_text(encoding="utf-8"))
    descriptor = json.loads(ANGEL_DESCRIPTOR.read_text(encoding="utf-8"))
    audio = PROJECT_DIR / "TuringResources" / str(descriptor["audioFile"])
    compilation = compile_allphone_viseme_track(audio, build_root / "golden-angel")
    generated = {
        "timeline": {
            "sampleRate": compilation.timeline.sample_rate,
            "sampleCount": compilation.timeline.sample_count,
            "durationSeconds": compilation.timeline.duration_seconds,
            "framesPerSecond": compilation.timeline.frames_per_second,
            "samplesPerNominalFrame": compilation.timeline.samples_per_nominal_frame,
            "frameCount": compilation.timeline.frame_count,
        },
        "requiredPoseFamilies": POSES,
        "runsSHA256": _compact_runs_hash(compilation.runs),
        "runs": compilation.runs,
        "summary": {
            "poseFrameCounts": compilation.pose_frame_counts,
            "speechFrameCount": (
                compilation.timeline.frame_count
                - compilation.pose_frame_counts["rest"]
            ),
            "silenceFrameCount": compilation.pose_frame_counts["rest"],
            "unknownPhoneCount": compilation.unknown_phone_count,
            "runCount": len(compilation.runs),
            "warnings": list(compilation.warnings),
        },
    }
    for field in ("timeline", "requiredPoseFamilies", "runs", "summary", "runsSHA256"):
        if generated[field] != checked[field]:
            raise ValueError(f"Angel golden reproduction failed at {field}")
    if generated["runsSHA256"] != ANGEL_GOLDEN_RUNS_SHA256:
        raise ValueError("Angel golden run SHA does not match the locked value")
    return generated


def _manifest_for(
    source: FixedCharacterVocalInput,
    descriptor_sha256: str,
    alignment: dict[str, Any],
    *,
    build_root: Path = BUILD_ROOT,
) -> dict[str, Any]:
    compilation = compile_allphone_viseme_track(
        source.source_path,
        build_root / "work" / Path(source.audio_file).stem,
        speech_boundary_policy="pocketsphinxNonSilencePhoneIntervals",
        enforce_angel_quality=False,
    )
    timeline = compilation.timeline
    runs = compilation.runs
    counts = compilation.pose_frame_counts
    return {
        "schemaVersion": 1,
        "compilerVersion": COMPILER_VERSION,
        "trackID": source.track_id,
        "characterID": source.character_id,
        "role": source.role,
        "audioFile": source.audio_file,
        "audioResourcePath": source.audio_resource_path,
        "audioSHA256": sha256_file(source.source_path),
        "blendShapeDescriptorResourcePath": (
            "CharacterLibrary/FacialPerformance/"
            f"{source.character_id}_infected_vocal_blendshape.json"
        ),
        "blendShapeDescriptorSHA256": descriptor_sha256,
        "looping": source.looping,
        "timeline": {
            "sampleRate": timeline.sample_rate,
            "sampleCount": timeline.sample_count,
            "durationSeconds": timeline.duration_seconds,
            "framesPerSecond": timeline.frames_per_second,
            "samplesPerNominalFrame": timeline.samples_per_nominal_frame,
            "frameCount": timeline.frame_count,
        },
        "requiredPoseFamilies": POSES,
        "alignment": alignment,
        "runsSHA256": _compact_runs_hash(runs),
        "runs": runs,
        "summary": {
            "poseFrameCounts": counts,
            "speechFrameCount": timeline.frame_count - counts["rest"],
            "silenceFrameCount": counts["rest"],
            "unknownPhoneCount": compilation.unknown_phone_count,
            "runCount": len(runs),
            "warnings": list(compilation.warnings),
        },
    }


def _catalog(inputs: tuple[FixedCharacterVocalInput, ...]) -> dict[str, Any]:
    if not inputs:
        raise ValueError("Fixed-character catalog cannot be empty")
    character_id = inputs[0].character_id
    if any(item.character_id != character_id for item in inputs):
        raise ValueError("Fixed-character catalog cannot mix character identities")
    return {
        "schemaVersion": 1,
        "catalogID": f"{character_id}.infected.vocalVisemes.v1",
        "characterID": character_id,
        "compilerVersion": COMPILER_VERSION,
        "entries": [
            {
                "role": item.role,
                "audioFile": item.audio_file,
                "audioSHA256": sha256_file(item.source_path),
                "looping": item.looping,
                "manifestResourcePath": item.manifest_resource_path,
            }
            for item in inputs
        ],
    }


def _reported_path(path: Path) -> str:
    try:
        return path.relative_to(REPOSITORY_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def _write_character_after_golden(
    configuration: FixedCharacterConfiguration,
    *,
    catalog_output: Path,
    manifest_output_root: Path,
    build_root: Path,
    angel_runs_sha256: str,
) -> dict[str, Any]:
    inputs = discover_character_inputs(configuration.character_id)
    descriptor_sha256 = sha256_file(configuration.blendshape_descriptor)
    alignment = _alignment_identity()
    manifests = [
        _manifest_for(
            item,
            descriptor_sha256,
            alignment,
            build_root=build_root,
        )
        for item in inputs
    ]
    catalog = _catalog(inputs)
    for item, manifest in zip(inputs, manifests, strict=True):
        _validate_manifest(manifest, item, descriptor_sha256, alignment)
    changed: list[str] = []
    for item, manifest in zip(inputs, manifests, strict=True):
        output = manifest_output_root / item.output_name
        if _write_if_changed(output, manifest):
            changed.append(_reported_path(output))
    if _write_if_changed(catalog_output, catalog):
        changed.append(_reported_path(catalog_output))
    validate_character_outputs(
        configuration.character_id,
        inputs=inputs,
        catalog=catalog,
        manifests=manifests,
        catalog_output=catalog_output,
        manifest_output_root=manifest_output_root,
    )
    return {
        "characterID": configuration.character_id,
        "catalogID": configuration.catalog_id,
        "angelRunsSHA256": angel_runs_sha256,
        "manifestCount": len(manifests),
        "changed": changed,
    }


def write_character(
    character_id: str,
    *,
    catalog_output: Path | None = None,
    manifest_output_root: Path | None = None,
    build_root: Path = BUILD_ROOT,
) -> dict[str, Any]:
    configuration = configuration_for(character_id)
    golden = golden_angel(build_root=build_root)
    return _write_character_after_golden(
        configuration,
        catalog_output=catalog_output or configuration.catalog_output,
        manifest_output_root=(
            manifest_output_root or configuration.manifest_output_root
        ),
        build_root=build_root / configuration.character_id,
        angel_runs_sha256=golden["runsSHA256"],
    )


def write_characters(
    character_ids: Iterable[str] = SUPPORTED_CHARACTER_IDS,
    *,
    facial_output_root: Path = FACIAL_ROOT,
    build_root: Path = BUILD_ROOT,
) -> dict[str, Any]:
    configurations = _configurations_for(character_ids)
    golden = golden_angel(build_root=build_root)
    results = [
        _write_character_after_golden(
            configuration,
            catalog_output=(
                facial_output_root
                / f"{configuration.character_id}_vocal_viseme_catalog.json"
            ),
            manifest_output_root=(
                facial_output_root / configuration.manifest_folder
            ),
            build_root=build_root / configuration.character_id,
            angel_runs_sha256=golden["runsSHA256"],
        )
        for configuration in configurations
    ]
    return {
        "angelRunsSHA256": golden["runsSHA256"],
        "characterCount": len(results),
        "manifestCount": sum(int(item["manifestCount"]) for item in results),
        "changed": [path for item in results for path in item["changed"]],
        "characters": results,
    }


def write(
    *,
    catalog_output: Path = CATALOG_OUTPUT,
    manifest_output_root: Path = MANIFEST_OUTPUT_ROOT,
    build_root: Path = BUILD_ROOT,
) -> dict[str, Any]:
    """Compatibility entry point for the original Dad-only authoring command."""

    return write_character(
        CHARACTER_ID,
        catalog_output=catalog_output,
        manifest_output_root=manifest_output_root,
        build_root=build_root,
    )


def _validate_manifest(
    manifest: dict[str, Any],
    source: FixedCharacterVocalInput,
    descriptor_sha256: str,
    alignment: dict[str, Any],
) -> None:
    expected_frame_count = (
        int(manifest["timeline"]["sampleCount"]) + 799
    ) // 800
    expected = {
        "schemaVersion": 1,
        "compilerVersion": COMPILER_VERSION,
        "trackID": source.track_id,
        "characterID": source.character_id,
        "role": source.role,
        "audioFile": source.audio_file,
        "audioResourcePath": source.audio_resource_path,
        "audioSHA256": sha256_file(source.source_path),
        "blendShapeDescriptorResourcePath": (
            "CharacterLibrary/FacialPerformance/"
            f"{source.character_id}_infected_vocal_blendshape.json"
        ),
        "blendShapeDescriptorSHA256": descriptor_sha256,
        "looping": source.looping,
        "requiredPoseFamilies": POSES,
        "alignment": alignment,
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"{source.output_name}: stale {key}")
    timeline = manifest.get("timeline", {})
    if (
        timeline.get("sampleRate") != 48_000
        or timeline.get("framesPerSecond") != 60
        or timeline.get("samplesPerNominalFrame") != 800
        or timeline.get("frameCount") != expected_frame_count
        or timeline.get("sampleCount", 0) <= 0
        or abs(
            float(timeline.get("durationSeconds", -1))
            - int(timeline["sampleCount"]) / 48_000
        )
        > 0.5 / 48_000
    ):
        raise ValueError(f"{source.output_name}: invalid timeline")
    runs = manifest.get("runs", [])
    if not runs or manifest.get("runsSHA256") != _compact_runs_hash(runs):
        raise ValueError(f"{source.output_name}: invalid runs hash")
    cursor = 0
    prior_pose: str | None = None
    counts = {pose: 0 for pose in POSES}
    for run in runs:
        start = int(run.get("startFrame", -1))
        end = int(run.get("endFrameExclusive", -1))
        pose = run.get("pose")
        if start != cursor or end <= start or end > expected_frame_count:
            raise ValueError(f"{source.output_name}: noncontiguous runs")
        if pose not in counts or pose == prior_pose:
            raise ValueError(f"{source.output_name}: invalid pose runs")
        counts[pose] += end - start
        cursor, prior_pose = end, pose
    summary = manifest.get("summary", {})
    if (
        cursor != expected_frame_count
        or summary.get("poseFrameCounts") != counts
        or summary.get("speechFrameCount") != expected_frame_count - counts["rest"]
        or summary.get("silenceFrameCount") != counts["rest"]
        or summary.get("runCount") != len(runs)
    ):
        raise ValueError(f"{source.output_name}: stale summary")


def validate_character_outputs(
    character_id: str,
    *,
    inputs: tuple[FixedCharacterVocalInput, ...] | None = None,
    catalog: dict[str, Any] | None = None,
    manifests: list[dict[str, Any]] | None = None,
    catalog_output: Path | None = None,
    manifest_output_root: Path | None = None,
) -> dict[str, Any]:
    configuration = configuration_for(character_id)
    catalog_output = catalog_output or configuration.catalog_output
    manifest_output_root = (
        manifest_output_root or configuration.manifest_output_root
    )
    inputs = inputs or discover_character_inputs(configuration.character_id)
    descriptor_sha256 = sha256_file(configuration.blendshape_descriptor)
    alignment = _alignment_identity()
    catalog = catalog or json.loads(catalog_output.read_text(encoding="utf-8"))
    if (
        catalog.get("schemaVersion") != 1
        or catalog.get("catalogID") != configuration.catalog_id
        or catalog.get("characterID") != configuration.character_id
        or catalog.get("compilerVersion") != COMPILER_VERSION
        or len(catalog.get("entries", [])) != 9
    ):
        raise ValueError(
            f"{configuration.character_id} viseme catalog identity is invalid"
        )
    expected_catalog = _catalog(inputs)
    if catalog != expected_catalog:
        raise ValueError(f"{configuration.character_id} viseme catalog is stale")
    manifest_paths = [item.manifest_resource_path for item in inputs]
    if len(set(manifest_paths)) != 9 or any(".." in Path(path).parts for path in manifest_paths):
        raise ValueError(
            f"{configuration.character_id} manifest resource paths are invalid"
        )
    loaded = manifests or [
        json.loads(
            (manifest_output_root / item.output_name).read_text(encoding="utf-8")
        )
        for item in inputs
    ]
    if len(loaded) != 9:
        raise ValueError(
            f"{configuration.character_id} must have exactly nine viseme manifests"
        )
    for source, manifest in zip(inputs, loaded, strict=True):
        _validate_manifest(manifest, source, descriptor_sha256, alignment)
    actual_outputs = sorted(manifest_output_root.glob("*.visemes.json"))
    expected_outputs = sorted(
        manifest_output_root / item.output_name
        for item in inputs
    )
    if actual_outputs != expected_outputs:
        raise ValueError(
            f"{configuration.character_id} viseme output directory contains "
            "an unexpected file set"
        )
    forbidden_audio = [
        path for path in manifest_output_root.rglob("*")
        if path.suffix.lower() in {".wav", ".mp3", ".m4a"}
    ]
    if forbidden_audio:
        raise ValueError(
            f"{configuration.character_id} viseme directory contains copied audio: "
            f"{forbidden_audio}"
        )
    return {
        "characterID": configuration.character_id,
        "catalogID": configuration.catalog_id,
        "manifestCount": len(loaded),
        "descriptorSHA256": descriptor_sha256,
        "runsSHA256": [manifest["runsSHA256"] for manifest in loaded],
    }


def validate_outputs(
    *,
    inputs: tuple[FixedCharacterVocalInput, ...] | None = None,
    catalog: dict[str, Any] | None = None,
    manifests: list[dict[str, Any]] | None = None,
    manifest_output_root: Path = MANIFEST_OUTPUT_ROOT,
) -> dict[str, Any]:
    """Compatibility entry point for the original Dad-only authoring command."""

    return validate_character_outputs(
        CHARACTER_ID,
        inputs=inputs,
        catalog=catalog,
        manifests=manifests,
        catalog_output=CATALOG_OUTPUT,
        manifest_output_root=manifest_output_root,
    )


def validate_characters(
    character_ids: Iterable[str] = SUPPORTED_CHARACTER_IDS,
    *,
    facial_output_root: Path = FACIAL_ROOT,
) -> dict[str, Any]:
    configurations = _configurations_for(character_ids)
    results = []
    for configuration in configurations:
        results.append(
            validate_character_outputs(
                configuration.character_id,
                catalog_output=(
                    facial_output_root
                    / f"{configuration.character_id}_vocal_viseme_catalog.json"
                ),
                manifest_output_root=(
                    facial_output_root / configuration.manifest_folder
                ),
            )
        )
    return {
        "characterCount": len(results),
        "manifestCount": sum(int(item["manifestCount"]) for item in results),
        "characters": results,
    }


def inspect_character(character_id: str) -> dict[str, Any]:
    configuration = configuration_for(character_id)
    inputs = discover_character_inputs(configuration.character_id)
    items = []
    ffprobe = shutil.which("ffprobe")
    for source in inputs:
        duration: float | None = None
        if ffprobe:
            result = subprocess.run(
                [
                    ffprobe,
                    "-v", "error",
                    "-show_entries", "format=duration",
                    "-of", "default=noprint_wrappers=1:nokey=1",
                    str(source.source_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            duration = float(result.stdout.strip())
        items.append({
            "role": source.role,
            "file": source.audio_file,
            "source": source.source_path.relative_to(REPOSITORY_ROOT).as_posix(),
            "sha256": sha256_file(source.source_path),
            "durationSeconds": duration,
            "output": (
                configuration.manifest_output_root / source.output_name
            ).relative_to(REPOSITORY_ROOT).as_posix(),
        })
    return {
        "characterID": configuration.character_id,
        "catalogID": configuration.catalog_id,
        "characterDescriptor": (
            configuration.character_descriptor
            .relative_to(REPOSITORY_ROOT)
            .as_posix()
        ),
        "blendShapeDescriptor": (
            configuration.blendshape_descriptor
            .relative_to(REPOSITORY_ROOT)
            .as_posix()
        ),
        "blendShapeDescriptorSHA256": sha256_file(
            configuration.blendshape_descriptor
        ),
        "catalog": (
            configuration.catalog_output.relative_to(REPOSITORY_ROOT).as_posix()
        ),
        "alignment": _alignment_identity(),
        "inputs": items,
    }


def inspect_characters(
    character_ids: Iterable[str] = SUPPORTED_CHARACTER_IDS,
) -> dict[str, Any]:
    results = [
        inspect_character(configuration.character_id)
        for configuration in _configurations_for(character_ids)
    ]
    return {
        "characterCount": len(results),
        "manifestCount": sum(len(item["inputs"]) for item in results),
        "characters": results,
    }


def inspect() -> dict[str, Any]:
    """Compatibility entry point for the original Dad-only authoring command."""

    return inspect_character(CHARACTER_ID)
