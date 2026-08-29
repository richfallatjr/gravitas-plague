from __future__ import annotations

from dataclasses import dataclass
from array import array
from importlib import metadata
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
from typing import Any
import wave

from .config import (
    AUDIO_ROOT,
    CONFIG_ROOT,
    DESCRIPTOR_ROOT,
    PROJECT_ROOT,
    TOOLCHAIN_ROOT as SOURCE_TOOLCHAIN_ROOT,
    load_compiler_configuration,
)
from .hashing import deterministic_tree_sha256, sha256_file
from .mfa_runner import MFAModelPaths, align_one
from .registry import load_registry


_VERSION_LINE = re.compile(r"([0-9]+(?:\.[0-9A-Za-z]+)+(?:a[0-9]+)?)")


@dataclass(frozen=True, slots=True)
class ToolchainLayout:
    root: Path
    mfa_prefix: Path
    python_prefix: Path
    model_root: Path
    mfa: Path
    ffmpeg: Path
    ffprobe: Path
    apple_probe: Path

    @classmethod
    def at(cls, root: Path | None = None) -> "ToolchainLayout":
        root = (root or PROJECT_ROOT / ".mind-eye-toolchains").resolve()
        mfa_prefix = root / "mfa"
        return cls(
            root=root,
            mfa_prefix=mfa_prefix,
            python_prefix=root / "python",
            model_root=root / "mfa-models",
            mfa=mfa_prefix / "bin" / "mfa",
            ffmpeg=mfa_prefix / "bin" / "ffmpeg",
            ffprobe=mfa_prefix / "bin" / "ffprobe",
            apple_probe=root / "bin" / "mind-eye-audio-timeline-probe",
        )


@dataclass(frozen=True, slots=True)
class DoctorResult:
    status: str
    checks: tuple[dict[str, str], ...]
    layout: ToolchainLayout
    lock: dict[str, Any] | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "checks": list(self.checks),
            "toolchainRoot": self.layout.root.as_posix(),
        }


def _command(arguments: list[str], *, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(arguments, capture_output=True, check=False, env=env)
    text = (completed.stdout + completed.stderr).decode("utf-8", errors="replace").strip()
    if completed.returncode != 0:
        raise RuntimeError(f"{Path(arguments[0]).name} failed ({completed.returncode}): {text}")
    return text


def _package_version(name: str) -> str:
    try:
        return metadata.version(name)
    except metadata.PackageNotFoundError as error:
        raise RuntimeError(f"Required Python distribution is missing: {name}") from error


def _conda_package_version(layout: ToolchainLayout, name: str) -> str:
    matches = sorted(layout.mfa_prefix.glob(f"conda-meta/{name}-*.json"))
    versions: set[str] = set()
    for path in matches:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("name") == name and isinstance(payload.get("version"), str):
            versions.add(payload["version"])
    if len(versions) != 1:
        raise RuntimeError(f"Expected one conda version for {name}, found {sorted(versions)}")
    return versions.pop()


def _first_version(text: str, label: str) -> str:
    match = _VERSION_LINE.search(text)
    if not match:
        raise RuntimeError(f"Could not parse {label} version: {text}")
    return match.group(1)


def _model_candidates(layout: ToolchainLayout, kind: str) -> list[Path]:
    roots = [
        layout.model_root / "pretrained_models" / kind,
        layout.model_root / "pretrained_models",
    ]
    candidates: set[Path] = set()
    for root in roots:
        if root.exists():
            candidates.update(
                path for path in root.rglob("english_us_arpa*")
                if path.is_file() or path.is_dir()
            )
    return sorted(candidates, key=lambda path: (len(path.parts), path.as_posix()))


def resolve_model_path(layout: ToolchainLayout, kind: str) -> Path:
    candidates = _model_candidates(layout, kind)
    direct = [path for path in candidates if path.parent.name == kind]
    selected = direct or candidates
    if len(selected) != 1:
        raise RuntimeError(
            f"Expected exactly one resolved {kind} english_us_arpa model; "
            f"found {[path.as_posix() for path in selected]}"
        )
    return selected[0]


def _verify_model_catalog(layout: ToolchainLayout, kind: str, version: str) -> None:
    cache_path = layout.model_root / "pretrained_models" / "cache.json"
    payload = json.loads(cache_path.read_text(encoding="utf-8"))
    record = payload.get(kind, {}).get("english_us_arpa", {}).get(f"v{version}")
    if (
        not isinstance(record, list) or len(record) < 5
        or record[0] != "english_us_arpa"
        or record[2] != f"v{version}"
    ):
        raise RuntimeError(f"MFA model catalog does not contain {kind} english_us_arpa {version}")
    resolved = resolve_model_path(layout, kind)
    if resolved.name != record[4]:
        raise RuntimeError(f"Resolved {kind} model filename does not match the versioned MFA catalog")


def hash_model(path: Path) -> str:
    return deterministic_tree_sha256(
        path,
        ignored_names=frozenset({"logs.db", "corpus.db", ".DS_Store"}),
    ) if path.is_dir() else sha256_file(path)


def _silero_model_path() -> Path:
    try:
        import silero_vad
    except ImportError as error:
        raise RuntimeError("silero-vad import failed") from error
    package = Path(silero_vad.__file__).resolve().parent
    candidates = sorted(package.rglob("silero_vad.onnx"))
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one Silero ONNX model, found {len(candidates)}")
    return candidates[0]


def installed_distribution_sha256(name: str) -> str:
    distribution = metadata.distribution(name)
    files = sorted(distribution.files or [], key=lambda item: str(item))
    import hashlib
    digest = hashlib.sha256()
    for relative in files:
        path = Path(distribution.locate_file(relative))
        if not path.is_file() or path.name == "RECORD":
            continue
        digest.update(str(relative).encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(path.stat().st_size).encode("ascii"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def validate_version_pins(mfa_version: str, versions: dict[str, str]) -> None:
    if mfa_version != "3.3.9" or not versions["kalpy"].startswith("0.9."):
        raise RuntimeError(f"MFA/kalpy pin mismatch: MFA={mfa_version} kalpy={versions['kalpy']}")
    expected = {
        "silero-vad": "6.2.1",
        "onnxruntime": "1.29.0",
        "torch": "2.9.1",
        "torchaudio": "2.9.1",
    }
    for name, wanted in expected.items():
        if versions[name] != wanted:
            raise RuntimeError(f"{name} pin mismatch: expected {wanted}, got {versions[name]}")
    if not versions["numpy"].startswith("2."):
        raise RuntimeError(f"NumPy must be 2.x; got {versions['numpy']}")


def validate_toolchain_lock(actual: dict[str, Any], expected: dict[str, Any]) -> None:
    if actual != expected:
        raise RuntimeError("Toolchain lock is stale or does not match the installed environment")


def collect_environment(layout: ToolchainLayout) -> dict[str, Any]:
    if platform.machine() != "arm64":
        raise RuntimeError(f"Phase 6 requires native arm64; got {platform.machine()}")
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError(f"Phase 6 requires Python 3.11.x; got {platform.python_version()}")
    expected_python = layout.python_prefix / "bin" / "python"
    if Path(sys.executable).resolve() != expected_python.resolve():
        raise RuntimeError(f"Doctor must run with isolated interpreter {expected_python}")
    for executable in (layout.mfa, layout.ffmpeg, layout.ffprobe, layout.apple_probe):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise RuntimeError(f"Required executable is missing: {executable}")
    child_env = dict(os.environ)
    child_env["MFA_ROOT_DIR"] = str(layout.model_root)
    mfa_version = _first_version(_command([str(layout.mfa), "version"], env=child_env), "MFA")
    ffmpeg_version = _first_version(_command([str(layout.ffmpeg), "-version"]), "ffmpeg")
    ffprobe_version = _first_version(_command([str(layout.ffprobe), "-version"]), "ffprobe")
    versions = {
        "kalpy": _conda_package_version(layout, "kalpy"),
        "silero-vad": _package_version("silero-vad"),
        "onnxruntime": _package_version("onnxruntime"),
        "torch": _package_version("torch"),
        "torchaudio": _package_version("torchaudio"),
        "numpy": _package_version("numpy"),
    }
    validate_version_pins(mfa_version, versions)
    try:
        import montreal_forced_aligner  # noqa: F401
        import kalpy  # noqa: F401
        import onnxruntime
        import torch
        import torchaudio
    except Exception as error:
        raise RuntimeError(f"Pinned authoring imports failed: {error}") from error
    if "CPUExecutionProvider" not in onnxruntime.get_available_providers():
        raise RuntimeError("ONNX Runtime CPUExecutionProvider is unavailable")
    if torch.__version__.split("+")[0] != torchaudio.__version__.split("+")[0]:
        raise RuntimeError("Torch and TorchAudio versions are incompatible")
    model_paths = {kind: resolve_model_path(layout, kind) for kind in ("acoustic", "dictionary", "g2p")}
    for kind in model_paths:
        _command([str(layout.mfa), "model", "inspect", kind, "english_us_arpa"], env=child_env)
        expected_version = "2.0.0a" if kind == "g2p" else "3.0.0"
        _verify_model_catalog(layout, kind, expected_version)
    silero_model = _silero_model_path()
    return {
        "pythonVersion": platform.python_version(),
        "mfaVersion": mfa_version,
        "kalpyVersion": versions["kalpy"],
        "ffmpegVersion": ffmpeg_version,
        "ffprobeVersion": ffprobe_version,
        "sileroVADVersion": versions["silero-vad"],
        "sileroPackageSHA256": installed_distribution_sha256("silero-vad"),
        "sileroModelSHA256": sha256_file(silero_model),
        "onnxruntimeVersion": versions["onnxruntime"],
        "torchVersion": versions["torch"],
        "torchaudioVersion": versions["torchaudio"],
        "numpyVersion": versions["numpy"],
        "modelPaths": model_paths,
        "modelHashes": {kind: hash_model(path) for kind, path in model_paths.items()},
    }


def build_lock(layout: ToolchainLayout) -> dict[str, Any]:
    environment = collect_environment(layout)
    source_config = SOURCE_TOOLCHAIN_ROOT / "toolchain.json"
    mfa_lock = SOURCE_TOOLCHAIN_ROOT / "mfa-lock-osx-arm64.yml"
    requirements_lock = SOURCE_TOOLCHAIN_ROOT / "requirements.lock.txt"
    for path in (source_config, mfa_lock, requirements_lock):
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Cannot build toolchain lock without generated input: {path}")
    return {
        "schemaVersion": 1,
        "toolchainConfigSHA256": sha256_file(source_config),
        "pythonVersion": environment["pythonVersion"],
        "mfaVersion": environment["mfaVersion"],
        "kalpyVersion": environment["kalpyVersion"],
        "ffmpegVersion": environment["ffmpegVersion"],
        "ffprobeVersion": environment["ffprobeVersion"],
        "sileroVADVersion": environment["sileroVADVersion"],
        "sileroPackageSHA256": environment["sileroPackageSHA256"],
        "sileroModelSHA256": environment["sileroModelSHA256"],
        "onnxruntimeVersion": environment["onnxruntimeVersion"],
        "torchVersion": environment["torchVersion"],
        "torchaudioVersion": environment["torchaudioVersion"],
        "numpyVersion": environment["numpyVersion"],
        "models": {
            kind: {
                "name": "english_us_arpa",
                "version": "2.0.0a" if kind == "g2p" else "3.0.0",
                "resolvedPathKind": "mfa-pretrained-cache",
                "sha256": environment["modelHashes"][kind],
            }
            for kind in ("acoustic", "dictionary", "g2p")
        },
        "mfaEnvironmentLockSHA256": sha256_file(mfa_lock),
        "pythonRequirementsLockSHA256": sha256_file(requirements_lock),
    }


def _run_mfa_smoke_test(
    layout: ToolchainLayout,
    *,
    model_paths: dict[str, Path],
    build_root: Path,
) -> None:
    sample_rate = 16_000
    sample_count = sample_rate // 2
    build_root.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix=".doctor-mfa-", dir=build_root) as temporary:
        root = Path(temporary)
        audio_path = root / "synthetic.wav"
        transcript_path = root / "synthetic.txt"
        output_path = root / "alignment.json"
        samples = array(
            "h",
            (
                int(
                    8_000
                    * math.sin(2 * math.pi * 180 * index / sample_rate)
                    * math.sin(math.pi * index / sample_count)
                )
                for index in range(sample_count)
            ),
        )
        if sys.byteorder != "little":
            samples.byteswap()
        with wave.open(str(audio_path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(sample_rate)
            output.writeframes(samples.tobytes())
        transcript_path.write_text("test\n", encoding="utf-8")
        align_one(
            mfa=layout.mfa,
            analysis_wav=audio_path,
            transcript_path=transcript_path,
            output_path=output_path,
            temporary_directory=root / "mfa-temp",
            config_path=SOURCE_TOOLCHAIN_ROOT.parent / "config" / "mfa_config.yaml",
            models=MFAModelPaths(
                acoustic_model=model_paths["acoustic"],
                dictionary=model_paths["dictionary"],
                g2p_model=model_paths["g2p"],
            ),
            mfa_root_directory=layout.model_root,
        )
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        tiers = payload.get("tiers") if isinstance(payload, dict) else None
        if not isinstance(tiers, dict) or not all(
            isinstance(tiers.get(name), dict)
            and isinstance(tiers[name].get("entries"), list)
            and tiers[name]["entries"]
            for name in ("words", "phones")
        ):
            raise RuntimeError("MFA synthetic alignment smoke test returned an unsupported JSON shape")


def run_doctor(layout: ToolchainLayout, *, require_lock: bool = True) -> DoctorResult:
    checks: list[dict[str, str]] = []
    environment = collect_environment(layout)
    checks.extend({"name": name, "status": "PASS", "detail": str(value)} for name, value in (
        ("architecture", platform.machine()),
        ("python", environment["pythonVersion"]),
        ("mfa", environment["mfaVersion"]),
        ("kalpy", environment["kalpyVersion"]),
        ("ffmpeg", environment["ffmpegVersion"]),
        ("ffprobe", environment["ffprobeVersion"]),
        ("silero-vad", environment["sileroVADVersion"]),
        ("onnxruntime", environment["onnxruntimeVersion"]),
        ("torch", environment["torchVersion"]),
        ("torchaudio", environment["torchaudioVersion"]),
    ))
    registry = load_registry()
    if len(registry.entries) != 37 or len(registry.exclusions) != 8:
        raise RuntimeError(
            f"Registry count mismatch: eligible={len(registry.entries)} excluded={len(registry.exclusions)}"
        )
    checks.extend((
        {"name": "registry", "status": "PASS", "detail": "37"},
        {"name": "exclusions", "status": "PASS", "detail": "8"},
    ))
    for name, root in (("descriptorRoot", DESCRIPTOR_ROOT), ("audioRoot", AUDIO_ROOT)):
        if not root.is_dir():
            raise RuntimeError(f"Required repository root is missing: {root}")
        checks.append({"name": name, "status": "PASS", "detail": root.as_posix()})
    compiler_config = load_compiler_configuration()
    checks.extend((
        {"name": "compilerConfig", "status": "PASS", "detail": compiler_config.sha256},
        {
            "name": "phonemePoseMap",
            "status": "PASS",
            "detail": sha256_file(CONFIG_ROOT / "phoneme_pose_map.json"),
        },
        {
            "name": "pronunciationOverrides",
            "status": "PASS",
            "detail": sha256_file(CONFIG_ROOT / "pronunciation_overrides.dict"),
        },
    ))
    lock_path = SOURCE_TOOLCHAIN_ROOT / "toolchain.lock.json"
    lock: dict[str, Any] | None = None
    if require_lock:
        if not lock_path.is_file():
            raise RuntimeError(f"Toolchain lock is missing: {lock_path}")
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        expected = build_lock(layout)
        validate_toolchain_lock(lock, expected)
        checks.append({"name": "toolchainLock", "status": "PASS", "detail": sha256_file(lock_path)})
    build_root = PROJECT_ROOT / ".build" / "mind-eye-lipsync"
    build_root.mkdir(parents=True, exist_ok=True)
    probe = build_root / ".doctor-write-probe"
    probe.write_bytes(b"ok")
    probe.unlink()
    checks.append({"name": "workspaceWritable", "status": "PASS", "detail": build_root.as_posix()})
    _run_mfa_smoke_test(
        layout,
        model_paths=environment["modelPaths"],
        build_root=build_root,
    )
    checks.append({"name": "mfaSyntheticAlignment", "status": "PASS", "detail": "0.5 seconds"})
    return DoctorResult("PASS", tuple(checks), layout, lock)
