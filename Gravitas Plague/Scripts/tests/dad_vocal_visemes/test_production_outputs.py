from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys

import pytest


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
PROJECT_DIR = SCRIPT_ROOT.parent
REPOSITORY_ROOT = PROJECT_DIR.parent
APP_ROOT = PROJECT_DIR / "Gravitas Plague"
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from dad_vocal_visemes.compiler import (  # noqa: E402
    ANGEL_GOLDEN_RUNS_SHA256,
    ANGEL_OUTPUT,
    BLENDSHAPE_DESCRIPTOR,
    CATALOG_ID,
    CATALOG_OUTPUT,
    CHARACTER_ID,
    COMPILER_VERSION,
    FACIAL_ROOT,
    MANIFEST_OUTPUT_ROOT,
    POSES,
    SUPPORTED_CHARACTER_IDS,
    configuration_for,
    discover_character_inputs,
    discover_inputs,
    validate_characters,
    validate_outputs,
    write_characters,
)
import dad_vocal_visemes.compiler as dad_compiler  # noqa: E402


EXPECTED_INVENTORY = (
    (
        "presence_loop",
        "dad_breathing.wav",
        True,
        "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb",
    ),
    (
        "damage_hits",
        "dad-damaged-01.wav",
        False,
        "fd079a1794c72cd18b565a7398bbb3d601c18fce8be68c85578d0d10f67bf7a5",
    ),
    (
        "damage_hits",
        "dad-damaged-02.wav",
        False,
        "024cc7fc72276ac2501c729faa97aa5ef855f2739af4d1eba408a6304eca3e71",
    ),
    (
        "damage_hits",
        "dad-damaged-03.wav",
        False,
        "e28f6eba93636333ead99be7b9059bd9742136375b4aaf87fa1ab1e4e6581da1",
    ),
    (
        "damage_hits",
        "dad-damaged-04.wav",
        False,
        "4f5fd5842e046ab7a0fc3fb51d4fe38eb5ad4d2f923b3bacf53cb9fa262a2cbf",
    ),
    (
        "death",
        "dad-death-01.wav",
        False,
        "670ff38fd3eb5e8f95d1b5848ec346b9a9e7b2f1b610b61a4c6f93e97d40b2f4",
    ),
    (
        "death",
        "dad-death-02.wav",
        False,
        "bedad39a231b62e7acb4fc7462680d62d84367e5b3e341ccfe4761774853fcff",
    ),
    (
        "death",
        "dad-death-03.wav",
        False,
        "a06c5cf435c3597d7bbd6e98023dc170250e9a95c8bd807fda2ecb67746ff0dc",
    ),
    (
        "death",
        "dad-death-04.wav",
        False,
        "48d97a9a5558870a4ba4ee238f805ca4dd86465ffe3bace1898036f66b9dd205",
    ),
)

MANIFEST_KEYS = {
    "schemaVersion",
    "compilerVersion",
    "trackID",
    "characterID",
    "role",
    "audioFile",
    "audioResourcePath",
    "audioSHA256",
    "blendShapeDescriptorResourcePath",
    "blendShapeDescriptorSHA256",
    "looping",
    "timeline",
    "requiredPoseFamilies",
    "alignment",
    "runsSHA256",
    "runs",
    "summary",
}
ALIGNMENT_KEYS = {
    "mode",
    "engine",
    "engineVersion",
    "engineCommit",
    "resourceTreeSHA256",
    "acousticModelSHA256",
    "phoneLanguageModelSHA256",
    "transcriptSHA256",
    "VADModelSHA256",
    "phonePoseMapSHA256",
    "speechBoundaryPolicy",
}
TIMELINE_KEYS = {
    "sampleRate",
    "sampleCount",
    "durationSeconds",
    "framesPerSecond",
    "samplesPerNominalFrame",
    "frameCount",
}
SUMMARY_KEYS = {
    "poseFrameCounts",
    "speechFrameCount",
    "silenceFrameCount",
    "unknownPhoneCount",
    "runCount",
    "warnings",
}
LOWERCASE_SHA256 = re.compile(r"^[0-9a-f]{64}$")
NEW_CHARACTER_IDS = tuple(
    character_id
    for character_id in SUPPORTED_CHARACTER_IDS
    if character_id != CHARACTER_ID
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _runs_sha256(runs: list[dict[str, object]]) -> str:
    encoded = json.dumps(
        runs,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _load_catalog() -> dict[str, object]:
    return json.loads(CATALOG_OUTPUT.read_text(encoding="utf-8"))


def _load_manifest(resource_path: str) -> dict[str, object]:
    return json.loads((APP_ROOT / resource_path).read_text(encoding="utf-8"))


def _assert_no_timestamp_fields(value: object) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            assert "timestamp" not in key.casefold()
            assert key not in {"createdAt", "generatedAt", "modifiedAt"}
            _assert_no_timestamp_fields(child)
    elif isinstance(value, list):
        for child in value:
            _assert_no_timestamp_fields(child)


def _generated_character_snapshot(
    facial_root: Path,
    character_id: str,
) -> dict[str, bytes]:
    configuration = configuration_for(character_id)
    catalog_path = facial_root / f"{character_id}_vocal_viseme_catalog.json"
    catalog_bytes = catalog_path.read_bytes()
    catalog = json.loads(catalog_bytes)
    snapshot = {catalog_path.name: catalog_bytes}
    for entry in catalog["entries"]:
        manifest_name = Path(entry["manifestResourcePath"]).name
        manifest_path = facial_root / configuration.manifest_folder / manifest_name
        snapshot[f"{configuration.manifest_folder}/{manifest_name}"] = (
            manifest_path.read_bytes()
        )
    return snapshot


@pytest.fixture(scope="module")
def isolated_new_character_authoring_runs(
    tmp_path_factory: pytest.TempPathFactory,
) -> tuple[dict[str, dict[str, bytes]], dict[str, dict[str, bytes]]]:
    run_snapshots: list[dict[str, dict[str, bytes]]] = []
    for run_name in ("first", "second"):
        run_root = tmp_path_factory.mktemp(f"fixed-character-{run_name}")
        facial_root = run_root / "FacialPerformance"
        result = write_characters(
            NEW_CHARACTER_IDS,
            facial_output_root=facial_root,
            build_root=run_root / "workspace",
        )
        assert result["angelRunsSHA256"] == ANGEL_GOLDEN_RUNS_SHA256
        assert result["characterCount"] == 4
        assert result["manifestCount"] == 36
        run_snapshots.append({
            character_id: _generated_character_snapshot(
                facial_root,
                character_id,
            )
            for character_id in NEW_CHARACTER_IDS
        })
    return run_snapshots[0], run_snapshots[1]


def test_catalog_and_discovery_lock_exact_nine_entry_inventory() -> None:
    inputs = discover_inputs()
    catalog = _load_catalog()
    entries = catalog["entries"]

    assert catalog == {
        "schemaVersion": 1,
        "catalogID": CATALOG_ID,
        "characterID": CHARACTER_ID,
        "compilerVersion": COMPILER_VERSION,
        "entries": entries,
    }
    assert len(inputs) == len(entries) == 9
    assert [
        (item.role, item.audio_file, item.looping, _sha256(item.source_path))
        for item in inputs
    ] == list(EXPECTED_INVENTORY)
    assert [
        (
            entry["role"],
            entry["audioFile"],
            entry["looping"],
            entry["audioSHA256"],
        )
        for entry in entries
    ] == list(EXPECTED_INVENTORY)
    assert {entry["role"] for entry in entries} == {
        "presence_loop",
        "damage_hits",
        "death",
    }
    assert [entry["role"] for entry in entries].count("presence_loop") == 1
    assert [entry["role"] for entry in entries].count("damage_hits") == 4
    assert [entry["role"] for entry in entries].count("death") == 4
    assert len({entry["audioFile"] for entry in entries}) == 9
    assert len({entry["manifestResourcePath"] for entry in entries}) == 9


def test_all_nine_manifests_have_exact_schema_identity_and_source_hashes() -> None:
    catalog = _load_catalog()
    descriptor_sha256 = _sha256(BLENDSHAPE_DESCRIPTOR)

    for entry in catalog["entries"]:
        manifest = _load_manifest(entry["manifestResourcePath"])
        assert set(manifest) == MANIFEST_KEYS
        assert manifest["schemaVersion"] == 1
        assert manifest["compilerVersion"] == COMPILER_VERSION
        assert manifest["characterID"] == CHARACTER_ID
        assert manifest["role"] == entry["role"]
        assert manifest["audioFile"] == entry["audioFile"]
        assert manifest["audioSHA256"] == entry["audioSHA256"]
        assert manifest["looping"] is entry["looping"]
        assert manifest["requiredPoseFamilies"] == POSES == [
            "rest",
            "small",
            "wide",
            "round",
            "teeth",
        ]
        assert manifest["trackID"] == (
            f"dad.{entry['role']}.{Path(entry['audioFile']).stem}.visemes"
        )
        assert manifest["blendShapeDescriptorResourcePath"] == (
            "CharacterLibrary/FacialPerformance/"
            "dad_infected_vocal_blendshape.json"
        )
        assert manifest["blendShapeDescriptorSHA256"] == descriptor_sha256
        assert LOWERCASE_SHA256.fullmatch(manifest["audioSHA256"])
        assert LOWERCASE_SHA256.fullmatch(
            manifest["blendShapeDescriptorSHA256"]
        )


def test_all_nine_manifest_timelines_runs_summaries_and_hashes_are_integral() -> None:
    catalog = _load_catalog()

    for entry in catalog["entries"]:
        manifest = _load_manifest(entry["manifestResourcePath"])
        timeline = manifest["timeline"]
        alignment = manifest["alignment"]
        runs = manifest["runs"]
        summary = manifest["summary"]

        assert set(timeline) == TIMELINE_KEYS
        assert timeline["sampleRate"] == 48_000
        assert timeline["framesPerSecond"] == 60
        assert timeline["samplesPerNominalFrame"] == 800
        assert timeline["sampleCount"] > 0
        assert timeline["frameCount"] == (
            timeline["sampleCount"] + 799
        ) // 800
        assert timeline["durationSeconds"] == pytest.approx(
            timeline["sampleCount"] / 48_000,
            abs=0.5 / 48_000,
        )

        assert set(alignment) == ALIGNMENT_KEYS
        assert alignment["mode"] == "pocketsphinxAllPhone"
        assert alignment["engine"] == "pocketsphinx"
        assert alignment["engineVersion"] == "5.1.1"
        assert alignment["engineCommit"] == (
            "511126b492dcb267cf30d49d631946d7b61a9530"
        )
        assert alignment["transcriptSHA256"] is None
        assert alignment["speechBoundaryPolicy"] == (
            "pocketsphinxNonSilencePhoneIntervals"
        )
        for key in (
            "resourceTreeSHA256",
            "acousticModelSHA256",
            "phoneLanguageModelSHA256",
            "VADModelSHA256",
            "phonePoseMapSHA256",
        ):
            assert LOWERCASE_SHA256.fullmatch(alignment[key])

        assert runs
        assert manifest["runsSHA256"] == _runs_sha256(runs)
        assert LOWERCASE_SHA256.fullmatch(manifest["runsSHA256"])
        counts = {pose: 0 for pose in POSES}
        cursor = 0
        prior_pose = None
        for run in runs:
            assert set(run) == {"startFrame", "endFrameExclusive", "pose"}
            assert run["startFrame"] == cursor
            assert run["endFrameExclusive"] > run["startFrame"]
            assert run["endFrameExclusive"] <= timeline["frameCount"]
            assert run["pose"] in counts
            assert run["pose"] != prior_pose
            counts[run["pose"]] += (
                run["endFrameExclusive"] - run["startFrame"]
            )
            cursor = run["endFrameExclusive"]
            prior_pose = run["pose"]
        assert cursor == timeline["frameCount"]

        assert set(summary) == SUMMARY_KEYS
        assert summary["poseFrameCounts"] == counts
        assert sum(counts.values()) == timeline["frameCount"]
        assert summary["speechFrameCount"] == (
            timeline["frameCount"] - counts["rest"]
        )
        assert summary["speechFrameCount"] > 0
        assert summary["silenceFrameCount"] == counts["rest"]
        assert summary["runCount"] == len(runs)
        assert isinstance(summary["unknownPhoneCount"], int)
        assert summary["unknownPhoneCount"] >= 0
        assert isinstance(summary["warnings"], list)


def test_authoring_validator_accepts_current_outputs_and_rejects_run_damage() -> None:
    result = validate_outputs()
    assert result["catalogID"] == CATALOG_ID
    assert result["manifestCount"] == 9
    assert len(result["runsSHA256"]) == 9

    inputs = discover_inputs()
    catalog = _load_catalog()
    manifests = [
        _load_manifest(entry["manifestResourcePath"])
        for entry in catalog["entries"]
    ]
    manifests[0]["runs"][0]["endFrameExclusive"] += 1
    with pytest.raises(ValueError, match="invalid runs hash"):
        validate_outputs(inputs=inputs, catalog=catalog, manifests=manifests)


def test_dad_authoring_and_outputs_contain_no_amplitude_pose_fallback() -> None:
    audited_paths = [
        *sorted((SCRIPT_ROOT / "dad_vocal_visemes").glob("*.py")),
        *sorted((SCRIPT_ROOT / "fixed_character_vocal_visemes").glob("*.py")),
        SCRIPT_ROOT / "generate_dad_vocal_visemes.py",
        SCRIPT_ROOT / "generate_fixed_character_vocal_visemes.py",
        REPOSITORY_ROOT / "Scripts/build_dad_vocal_visemes.sh",
        REPOSITORY_ROOT / "Scripts/build_fixed_character_vocal_visemes.sh",
        REPOSITORY_ROOT / "Tools/DadVocalVisemeCompiler/main.swift",
        REPOSITORY_ROOT / "Tools/FixedCharacterVocalVisemeCompiler/main.swift",
        CATALOG_OUTPUT,
        *sorted(MANIFEST_OUTPUT_ROOT.glob("*.visemes.json")),
        *[
            configuration_for(character_id).catalog_output
            for character_id in NEW_CHARACTER_IDS
        ],
        *[
            path
            for character_id in NEW_CHARACTER_IDS
            for path in sorted(
                configuration_for(character_id)
                .manifest_output_root
                .glob("*.visemes.json")
            )
        ],
    ]
    source = "\n".join(path.read_text(encoding="utf-8") for path in audited_paths)
    forbidden = (
        "TuringGeneratedSpeechAnalyzer",
        "TuringSpeechAmplitudeEnvelope",
        "normalizedEnergy",
        "zeroCrossing",
        "decibels",
        "amplitude",
        "compatibilityDSP",
    )
    for term in forbidden:
        assert term.casefold() not in source.casefold(), term
    assert re.search(r"\brms\b", source, flags=re.IGNORECASE) is None


def test_checked_in_angel_run_payload_preserves_locked_golden_hash() -> None:
    angel = json.loads(ANGEL_OUTPUT.read_text(encoding="utf-8"))
    assert ANGEL_GOLDEN_RUNS_SHA256 == (
        "6a48f84827b2842fb3199c1bf4965113b3a65f8c55eedd7c0b23772c983b4a8a"
    )
    assert angel["runsSHA256"] == ANGEL_GOLDEN_RUNS_SHA256
    assert _runs_sha256(angel["runs"]) == ANGEL_GOLDEN_RUNS_SHA256
    assert angel["timeline"] == {
        "sampleRate": 48_000,
        "sampleCount": 6_994_565,
        "durationSeconds": 6_994_565 / 48_000,
        "framesPerSecond": 60,
        "samplesPerNominalFrame": 800,
        "frameCount": 8_744,
    }
    assert angel["requiredPoseFamilies"] == POSES
    assert angel["runs"][0]["startFrame"] == 0
    assert angel["runs"][-1]["endFrameExclusive"] == 8_744


def test_dad_authoring_is_byte_deterministic_across_isolated_runs(
    tmp_path: Path,
) -> None:
    snapshots: list[dict[str, bytes]] = []
    ordered_names: list[list[str]] = []
    ordered_run_hashes: list[list[str]] = []

    for run_name in ("first", "second"):
        run_root = tmp_path / run_name
        output_root = run_root / "output"
        catalog_output = output_root / "dad_vocal_viseme_catalog.json"
        manifest_output_root = output_root / "DadVisemes"
        result = dad_compiler.write(
            catalog_output=catalog_output,
            manifest_output_root=manifest_output_root,
            build_root=run_root / "workspace",
        )

        catalog_bytes = catalog_output.read_bytes()
        catalog = json.loads(catalog_bytes)
        manifest_names = [
            Path(entry["manifestResourcePath"]).name
            for entry in catalog["entries"]
        ]
        assert result["manifestCount"] == len(manifest_names) == 9
        assert result["angelRunsSHA256"] == ANGEL_GOLDEN_RUNS_SHA256
        assert [entry["audioFile"] for entry in catalog["entries"]] == [
            item[1] for item in EXPECTED_INVENTORY
        ]

        snapshot = {"dad_vocal_viseme_catalog.json": catalog_bytes}
        run_hashes: list[str] = []
        _assert_no_timestamp_fields(catalog)
        for manifest_name in manifest_names:
            manifest_path = manifest_output_root / manifest_name
            manifest_bytes = manifest_path.read_bytes()
            manifest = json.loads(manifest_bytes)
            snapshot[f"DadVisemes/{manifest_name}"] = manifest_bytes
            assert manifest["runsSHA256"] == _runs_sha256(manifest["runs"])
            run_hashes.append(manifest["runsSHA256"])
            _assert_no_timestamp_fields(manifest)

        snapshots.append(snapshot)
        ordered_names.append(manifest_names)
        ordered_run_hashes.append(run_hashes)

    assert ordered_names[0] == ordered_names[1]
    assert ordered_run_hashes[0] == ordered_run_hashes[1]
    assert list(snapshots[0]) == list(snapshots[1])
    assert snapshots[0] == snapshots[1]

    production = {
        "dad_vocal_viseme_catalog.json": CATALOG_OUTPUT.read_bytes(),
        **{
            f"DadVisemes/{path.name}": path.read_bytes()
            for path in sorted(MANIFEST_OUTPUT_ROOT.glob("*.visemes.json"))
        },
    }
    assert snapshots[0] == production


@pytest.mark.parametrize("character_id", NEW_CHARACTER_IDS)
def test_new_character_authoring_is_deterministic_and_integral(
    character_id: str,
    isolated_new_character_authoring_runs: tuple[
        dict[str, dict[str, bytes]],
        dict[str, dict[str, bytes]],
    ],
) -> None:
    first_runs, second_runs = isolated_new_character_authoring_runs
    first = first_runs[character_id]
    second = second_runs[character_id]
    configuration = configuration_for(character_id)
    inputs = discover_character_inputs(character_id)

    assert list(first) == list(second)
    assert first == second
    assert len(first) == 10

    production = {
        configuration.catalog_output.name: configuration.catalog_output.read_bytes(),
        **{
            f"{configuration.manifest_folder}/{path.name}": path.read_bytes()
            for path in sorted(
                configuration.manifest_output_root.glob("*.visemes.json")
            )
        },
    }
    assert first == production

    catalog = json.loads(first[configuration.catalog_output.name])
    assert catalog["catalogID"] == f"{character_id}.infected.vocalVisemes.v1"
    assert catalog["characterID"] == character_id
    assert catalog["compilerVersion"] == COMPILER_VERSION
    assert [entry["role"] for entry in catalog["entries"]] == [
        "presence_loop",
        *("damage_hits" for _ in range(4)),
        *("death" for _ in range(4)),
    ]
    assert [entry["audioFile"] for entry in catalog["entries"]] == [
        item.audio_file for item in inputs
    ]
    assert [Path(entry["manifestResourcePath"]).name for entry in catalog["entries"]] == [
        item.output_name for item in inputs
    ]
    assert len({entry["audioSHA256"] for entry in catalog["entries"]}) == 9
    _assert_no_timestamp_fields(catalog)

    descriptor_sha256 = _sha256(configuration.blendshape_descriptor)
    ordered_run_hashes: list[str] = []
    for source, entry in zip(inputs, catalog["entries"], strict=True):
        relative_name = (
            f"{configuration.manifest_folder}/"
            f"{Path(entry['manifestResourcePath']).name}"
        )
        manifest_bytes = first[relative_name]
        assert manifest_bytes.endswith(b"\n")
        manifest = json.loads(manifest_bytes)
        _assert_no_timestamp_fields(manifest)
        assert set(manifest) == MANIFEST_KEYS
        assert manifest["characterID"] == character_id
        assert manifest["trackID"] == source.track_id
        assert manifest["role"] == source.role
        assert manifest["audioFile"] == source.audio_file
        assert manifest["audioSHA256"] == _sha256(source.source_path)
        assert manifest["blendShapeDescriptorResourcePath"] == (
            "CharacterLibrary/FacialPerformance/"
            f"{character_id}_infected_vocal_blendshape.json"
        )
        assert manifest["blendShapeDescriptorSHA256"] == descriptor_sha256
        assert manifest["looping"] is source.looping
        assert manifest["requiredPoseFamilies"] == POSES
        assert manifest["alignment"]["mode"] == "pocketsphinxAllPhone"
        assert manifest["alignment"]["speechBoundaryPolicy"] == (
            "pocketsphinxNonSilencePhoneIntervals"
        )
        assert manifest["runsSHA256"] == _runs_sha256(manifest["runs"])
        ordered_run_hashes.append(manifest["runsSHA256"])

        cursor = 0
        prior_pose = None
        counts = {pose: 0 for pose in POSES}
        for run in manifest["runs"]:
            assert run["startFrame"] == cursor
            assert run["endFrameExclusive"] > cursor
            assert run["pose"] in counts
            assert run["pose"] != prior_pose
            counts[run["pose"]] += run["endFrameExclusive"] - cursor
            cursor = run["endFrameExclusive"]
            prior_pose = run["pose"]
        assert cursor == manifest["timeline"]["frameCount"]
        assert manifest["summary"]["poseFrameCounts"] == counts
        assert manifest["summary"]["runCount"] == len(manifest["runs"])

    second_catalog = json.loads(second[configuration.catalog_output.name])
    second_hashes = [
        json.loads(
            second[
                f"{configuration.manifest_folder}/"
                f"{Path(entry['manifestResourcePath']).name}"
            ]
        )["runsSHA256"]
        for entry in second_catalog["entries"]
    ]
    assert ordered_run_hashes == second_hashes
    assert not any(
        path.suffix.casefold() in {".wav", ".mp3", ".m4a"}
        for path in configuration.manifest_output_root.rglob("*")
    )


def test_all_fixed_character_manifest_basenames_are_globally_unique() -> None:
    names = [
        item.output_name
        for character_id in SUPPORTED_CHARACTER_IDS
        for item in discover_character_inputs(character_id)
    ]
    assert len(names) == 45
    assert len(set(names)) == 45
    assert "dad_breathing.visemes.json" in names
    for character_id in NEW_CHARACTER_IDS:
        assert f"{character_id}-dad_breathing.visemes.json" in names


def test_shared_presence_audio_keeps_shared_runs_but_distinct_character_identity() -> None:
    presence_manifests = []
    for character_id in SUPPORTED_CHARACTER_IDS:
        configuration = configuration_for(character_id)
        catalog = json.loads(
            configuration.catalog_output.read_text(encoding="utf-8")
        )
        entry = catalog["entries"][0]
        assert entry["role"] == "presence_loop"
        assert entry["audioFile"] == "dad_breathing.wav"
        manifest = json.loads(
            (
                configuration.manifest_output_root
                / Path(entry["manifestResourcePath"]).name
            ).read_text(encoding="utf-8")
        )
        presence_manifests.append(manifest)

    assert {
        manifest["runsSHA256"] for manifest in presence_manifests
    } == {"941e12f55eb520ee8d042d8348a8a0b0ab06f322b7f7bd306cf97bd10c2291c2"}
    assert [manifest["characterID"] for manifest in presence_manifests] == list(
        SUPPORTED_CHARACTER_IDS
    )
    assert len({manifest["trackID"] for manifest in presence_manifests}) == 5
    assert len({
        manifest["blendShapeDescriptorSHA256"]
        for manifest in presence_manifests
    }) == 5


def test_generic_validation_normalizes_to_canonical_character_order() -> None:
    result = validate_characters(reversed(SUPPORTED_CHARACTER_IDS))
    assert [item["characterID"] for item in result["characters"]] == list(
        SUPPORTED_CHARACTER_IDS
    )
    assert result["characterCount"] == 5
    assert result["manifestCount"] == 45
