from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import shutil
from tempfile import mkdtemp
from typing import Any

from .audio_decode import decode_wav, probe_audio, run_apple_timeline_probe
from .config import AUDIO_ROOT, CONFIG_ROOT, PROJECT_ROOT, TOOLCHAIN_ROOT as SOURCE_TOOLCHAIN_ROOT, load_compiler_configuration
from .descriptor_loader import reconcile_descriptor, resolve_descriptor
from .deterministic_json import write_atomic_json
from .dictionary import build_merged_dictionary
from .doctor import DoctorResult, ToolchainLayout, resolve_model_path, run_doctor
from .errors import ExitCode, MindEyeCompilerError
from .frame_expander import (
    apply_coarticulation,
    apply_manual_overrides,
    expand_frames,
    frames_sha256,
)
from .hashing import sha256_bytes, sha256_file
from .manifest import AnalysisProvenance, AuthoredFrameManifest, build_summary
from .manual_override import load_manual_override
from .mfa_json import MFAAlignment, parse_mfa_json, repair_boundary_absorbed_phones
from .mfa_runner import MFAModelPaths, align_one
from .phones import load_phone_pose_map, map_phone_intervals
from .preview_svg import render_preview_svg
from .quality import validate_alignment_quality
from .registry import load_registry
from .report import build_report
from .timeline import DecoderParity, compare_decoder_counts, parse_apple_probe_output, parse_pcm_wav
from .transcript import normalize_transcript
from .vad import VADResult, analyze_vad
from .validator import validate_manifest_file, validate_manifest_object


@dataclass(frozen=True, slots=True)
class CompileRequest:
    pr_id: str
    output: Path
    toolchain_root: Path
    workspace: Path | None = None
    manual_override: Path | None = None
    report_json: Path | None = None
    report_svg: Path | None = None
    keep_intermediates: bool = False
    force: bool = False


@dataclass(frozen=True, slots=True)
class CompileResult:
    pr_id: str
    output: Path
    frame_count: int
    duration_seconds: float
    frames_sha256: str
    warnings: tuple[str, ...]
    report_json: Path | None
    report_svg: Path | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": "PASS",
            "prID": self.pr_id,
            "output": self.output.as_posix(),
            "frameCount": self.frame_count,
            "durationSeconds": self.duration_seconds,
            "framesSHA256": self.frames_sha256,
            "warnings": list(self.warnings),
            "reportJSON": self.report_json.as_posix() if self.report_json else None,
            "reportSVG": self.report_svg.as_posix() if self.report_svg else None,
        }


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _validate_output(request: CompileRequest, audio_source: Path) -> None:
    canonical_audio = audio_source.parent.resolve()
    outputs = [request.output, request.report_json, request.report_svg]
    resolved = [path.resolve() for path in outputs if path is not None]
    if len(resolved) != len(set(resolved)):
        raise MindEyeCompilerError(
            "Manifest and diagnostic output paths must be distinct",
            exit_code=ExitCode.VALIDATION_FAILURE,
            diagnostic_code="collidingOutputPath",
        )
    for output in resolved:
        if _is_within(output, canonical_audio) or output == audio_source.resolve():
            raise MindEyeCompilerError(
                "Compiler outputs may not be written into the canonical audio directory",
                exit_code=ExitCode.VALIDATION_FAILURE,
                diagnostic_code="unsafeOutputPath",
            )
    if not request.force:
        existing = [path for path in outputs if path is not None and path.exists()]
        if existing:
            raise MindEyeCompilerError(
                "Output already exists; pass --force to replace it: "
                + ", ".join(path.as_posix() for path in existing),
                exit_code=ExitCode.VALIDATION_FAILURE,
                diagnostic_code="outputExists",
            )


def _workspace_for(request: CompileRequest, audio_hash: str) -> tuple[Path, bool]:
    allowed_root = (PROJECT_ROOT / ".build").resolve()
    if request.workspace is not None:
        workspace = request.workspace.resolve()
        if not _is_within(workspace, allowed_root):
            raise MindEyeCompilerError(
                "Compiler workspace must remain under the repository .build directory",
                exit_code=ExitCode.VALIDATION_FAILURE,
                diagnostic_code="unsafeWorkspace",
            )
        workspace.mkdir(parents=True, exist_ok=True)
        return workspace, False
    root = allowed_root / "mind-eye-lipsync" / "work"
    root.mkdir(parents=True, exist_ok=True)
    workspace = Path(mkdtemp(prefix=f"{request.pr_id}.{audio_hash[:12]}.", dir=root))
    return workspace, True


def _load_manual(path: Path | None, pr_id: str, frame_count: int) -> tuple[tuple[dict[str, object], ...], str | None]:
    canonical = CONFIG_ROOT / "manual_overrides" / f"{pr_id}.json"
    if path is None:
        path = canonical if canonical.is_file() else None
    if path is None:
        return (), None
    if path.resolve() != canonical.resolve():
        raise ValueError(
            "Audited manual overrides must use the canonical config/manual_overrides/<pr-id>.json path"
        )
    if not path.is_file():
        raise ValueError(f"Manual override does not exist: {path}")
    return load_manual_override(path, pr_id=pr_id, frame_count=frame_count), sha256_file(path)


def _write_svg_atomic(path: Path, svg: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.tmp"
    temporary.write_text(svg, encoding="utf-8")
    temporary.replace(path)


def compile_pr(
    request: CompileRequest,
    *,
    doctor_result: DoctorResult | None = None,
) -> CompileResult:
    layout = ToolchainLayout.at(request.toolchain_root)
    try:
        doctor = doctor_result or run_doctor(layout)
        if doctor.layout != layout or doctor.status != "PASS":
            raise RuntimeError("Injected doctor result does not match the requested toolchain")
    except Exception as error:
        raise MindEyeCompilerError(
            str(error), exit_code=ExitCode.TOOLCHAIN_FAILURE,
            diagnostic_code="toolchainUnavailable",
        ) from error
    registry = load_registry()
    try:
        entry = registry.require_entry(request.pr_id)
        descriptor = resolve_descriptor(request.pr_id)
        reconcile_descriptor(entry, descriptor)
        audio_source = (AUDIO_ROOT / entry.audio_file).resolve()
        expected_audio_root = AUDIO_ROOT.resolve()
        if not _is_within(audio_source, expected_audio_root) or not audio_source.is_file():
            raise ValueError(f"Canonical audio is missing or unsafe: {audio_source}")
        _validate_output(request, audio_source)
    except MindEyeCompilerError:
        raise
    except Exception as error:
        raise MindEyeCompilerError(
            str(error), exit_code=ExitCode.VALIDATION_FAILURE,
            diagnostic_code="sourceValidationFailed",
        ) from error

    audio_hash = sha256_file(audio_source)
    workspace, temporary_workspace = _workspace_for(request, audio_hash)
    config = load_compiler_configuration()
    transcript = normalize_transcript(descriptor.transcript)
    transcript_hash = sha256_bytes(transcript.hash_text.encode("utf-8"))
    lock_path = SOURCE_TOOLCHAIN_ROOT / "toolchain.lock.json"
    lock = doctor.lock
    if lock is None:
        raise MindEyeCompilerError(
            "Doctor did not load a toolchain lock",
            exit_code=ExitCode.TOOLCHAIN_FAILURE,
            diagnostic_code="toolchainLockMissing",
        )
    timeline_wav = workspace / "timeline-48000-mono-s16.wav"
    analysis_wav = workspace / "analysis-16000-mono-s16.wav"
    transcript_path = workspace / "transcript.txt"
    mfa_output = workspace / "alignment.json"
    transcript_path.write_text(transcript.alignment_text + "\n", encoding="utf-8")
    alignment: MFAAlignment | None = None
    vad: VADResult | None = None
    parity: DecoderParity | None = None
    try:
        probe_audio(layout.ffprobe, audio_source)
        decode_wav(layout.ffmpeg, audio_source, timeline_wav, sample_rate=48_000)
        timeline = parse_pcm_wav(timeline_wav)
        apple_count = parse_apple_probe_output(run_apple_timeline_probe(layout.apple_probe, audio_source))
        parity = compare_decoder_counts(timeline.sample_count, apple_count)
        decode_wav(layout.ffmpeg, timeline_wav, analysis_wav, sample_rate=16_000)
        vad = analyze_vad(
            analysis_wav,
            timeline_sample_count=timeline.sample_count,
            config=config.section("vad"),
            model_sha256=str(lock["sileroModelSHA256"]),
            package_version=str(lock["sileroVADVersion"]),
        )
        base_dictionary = resolve_model_path(layout, "dictionary")
        g2p_model = resolve_model_path(layout, "g2p")
        merged_dictionary = build_merged_dictionary(
            base_dictionary=base_dictionary,
            pronunciation_overrides=CONFIG_ROOT / "pronunciation_overrides.dict",
            transcript=transcript,
            g2p_model=g2p_model,
            destination=workspace / "english_us_arpa-merged.dict",
            extraction_root=workspace / "g2p-generation",
        )
        execution = align_one(
            mfa=layout.mfa,
            analysis_wav=analysis_wav,
            transcript_path=transcript_path,
            output_path=mfa_output,
            temporary_directory=workspace / "mfa-temp",
            config_path=CONFIG_ROOT / "mfa_config.yaml",
            models=MFAModelPaths(
                acoustic_model=resolve_model_path(layout, "acoustic"),
                dictionary=merged_dictionary.path,
                g2p_model=g2p_model,
            ),
            mfa_root_directory=layout.model_root,
        )
        alignment = parse_mfa_json(
            mfa_output,
            timeline_sample_count=timeline.sample_count,
            tolerance_ms=int(config.section("alignment")["phoneBoundaryToleranceMs"]),
        )
        alignment, boundary_repair_warnings = repair_boundary_absorbed_phones(
            alignment,
            vad.speech_spans,
            timeline_sample_count=timeline.sample_count,
            maximum_phone_samples=int(
                float(config.section("adjudication")["maximumPhoneDurationSeconds"])
                * 48_000
            ),
        )
        quality = validate_alignment_quality(
            alignment,
            vad.speech_spans,
            transcript_token_count=transcript.token_count,
            config=config.section("adjudication"),
        )
        pose_map = load_phone_pose_map()
        mapping = map_phone_intervals(alignment.phones, vad.speech_spans, pose_map)
        frames = expand_frames(
            timeline,
            mapping.spans,
            vad.speech_spans,
            speech_overlap_threshold=float(config.section("adjudication")["frameSpeechOverlapThreshold"]),
        )
        frames = apply_coarticulation(
            frames, pose_map,
            silence_barrier_frames=int(config.section("coarticulation")["silenceBarrierFrames"]),
        )
        operations, manual_hash = _load_manual(request.manual_override, request.pr_id, len(frames))
        if operations:
            frames = apply_manual_overrides(frames, operations)
        warnings = sorted(set(
            quality.warnings + mapping.warnings
            + boundary_repair_warnings
            + ((parity.warning,) if parity.warning else ())
            + transcript.substitutions
            + tuple(f"g2pGenerated:{word}" for word in merged_dictionary.g2p_words)
            + tuple(f"pronunciationOverride:{word}" for word in merged_dictionary.override_words)
        ))
        frame_hash = frames_sha256(frames)
        manifest = AuthoredFrameManifest(
            schema_version=1,
            compiler_version=config.compiler_version,
            pr_id=entry.pr_id,
            speaker_character_id=entry.speaker_character_id,
            interaction_surface=entry.interaction_surface,
            descriptor_resource_path=descriptor.descriptor_resource_path,
            descriptor_sha256=descriptor.descriptor_sha256,
            audio_resource_path=f"Turing/Audio/prerecordings/{entry.audio_file}",
            audio_sha256=audio_hash,
            transcript_sha256=transcript_hash,
            timeline=timeline,
            provenance=AnalysisProvenance(
                toolchain_lock_sha256=sha256_file(lock_path),
                compiler_config_sha256=config.sha256,
                phoneme_pose_map_sha256=sha256_file(CONFIG_ROOT / "phoneme_pose_map.json"),
                pronunciation_overrides_sha256=sha256_file(CONFIG_ROOT / "pronunciation_overrides.dict"),
                manual_override_sha256=manual_hash,
                mfa={
                    "version": "3.3.9",
                    "acousticModel": "english_us_arpa",
                    "acousticModelVersion": "3.0.0",
                    "dictionary": "english_us_arpa",
                    "dictionaryVersion": "3.0.0",
                    "g2pModel": "english_us_arpa",
                    "g2pModelVersion": "2.0.0a",
                    "retryUsed": execution.retry_used,
                    "rawOutputSHA256": sha256_file(mfa_output),
                },
                vad={
                    "name": "silero-vad",
                    "version": vad.package_version,
                    "backend": "onnx",
                    "modelSHA256": vad.model_sha256,
                    "configurationSHA256": vad.configuration_sha256,
                },
            ),
            frames_sha256=frame_hash,
            frames=frames,
            summary=build_summary(
                frames,
                aligned_word_count=quality.aligned_word_count,
                transcript_token_count=transcript.token_count,
                oov_words=merged_dictionary.oov_words,
                g2p_words=merged_dictionary.g2p_words,
                warnings=warnings,
            ),
        )
        payload = manifest.to_ordered_dict()
        validate_manifest_object(payload)
        if sha256_file(audio_source) != audio_hash:
            raise ValueError("Canonical source audio changed while compilation was running")
        write_atomic_json(request.output, payload)
        validate_manifest_file(request.output, verify_sources=True)
        manifest_sha256 = sha256_file(request.output)
        if request.report_json is not None:
            write_atomic_json(
                request.report_json,
                build_report(
                    payload,
                    alignment=alignment,
                    vad=vad,
                    parity=parity,
                    manifest_sha256=manifest_sha256,
                ),
            )
        if request.report_svg is not None:
            _write_svg_atomic(request.report_svg, render_preview_svg(payload, alignment=alignment, vad=vad))
        return CompileResult(
            pr_id=entry.pr_id,
            output=request.output,
            frame_count=timeline.frame_count,
            duration_seconds=timeline.duration_seconds,
            frames_sha256=frame_hash,
            warnings=tuple(warnings),
            report_json=request.report_json,
            report_svg=request.report_svg,
        )
    except MindEyeCompilerError:
        raise
    except ValueError as error:
        raise MindEyeCompilerError(
            str(error), exit_code=ExitCode.ALIGNMENT_QUALITY_FAILURE,
            diagnostic_code="alignmentOrManifestQualityFailed",
        ) from error
    except Exception as error:
        raise MindEyeCompilerError(
            str(error), exit_code=ExitCode.INTERNAL_ERROR,
            diagnostic_code="compileFailed",
        ) from error
    finally:
        if temporary_workspace and not request.keep_intermediates:
            build_root = (PROJECT_ROOT / ".build").resolve()
            if _is_within(workspace, build_root):
                shutil.rmtree(workspace, ignore_errors=True)
