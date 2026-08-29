from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from ..audio_decode import decode_wav, probe_audio, run_apple_timeline_probe
from ..config import CONFIG_ROOT, load_compiler_configuration
from ..dictionary import build_merged_dictionary
from ..doctor import ToolchainLayout, resolve_model_path, run_doctor
from ..frame_expander import apply_coarticulation, expand_frames
from ..hashing import sha256_bytes, sha256_file
from ..mfa_json import parse_mfa_json, repair_boundary_absorbed_phones
from ..mfa_runner import MFAModelPaths, align_one
from ..phones import load_phone_pose_map, map_phone_intervals
from ..quality import validate_alignment_quality
from ..timeline import compare_decoder_counts, parse_apple_probe_output, parse_pcm_wav
from ..transcript import normalize_transcript
from ..vad import analyze_vad


@dataclass(frozen=True, slots=True)
class VerbalCompilation:
    poses: list[str]
    evidence: list[int]
    transcript_sha256: str
    mfa_raw_output_sha256: str


@lru_cache(maxsize=2)
def _doctor(root: str):
    return run_doctor(ToolchainLayout.at(Path(root)))


def compile_verbal_filler(
    *,
    audio_source: Path,
    timeline_wav: Path,
    workspace: Path,
    transcript_text: str,
    toolchain_root: Path,
) -> VerbalCompilation:
    layout = ToolchainLayout.at(toolchain_root)
    doctor = _doctor(str(layout.root))
    config = load_compiler_configuration()
    transcript = normalize_transcript(transcript_text)
    transcript_sha = sha256_bytes(transcript.hash_text.encode("utf-8"))
    timeline = parse_pcm_wav(timeline_wav)
    probe_audio(layout.ffprobe, audio_source)
    apple_count = parse_apple_probe_output(
        run_apple_timeline_probe(layout.apple_probe, audio_source)
    )
    compare_decoder_counts(timeline.sample_count, apple_count)

    analysis_wav = workspace / "analysis-16000-mono-s16.wav"
    transcript_path = workspace / "transcript.txt"
    alignment_path = workspace / "alignment.json"
    transcript_path.write_text(transcript.alignment_text + "\n", encoding="utf-8")
    decode_wav(layout.ffmpeg, timeline_wav, analysis_wav, sample_rate=16_000)
    lock = doctor.lock
    if lock is None:
        raise ValueError("Pinned filler authoring toolchain lock is missing")
    vad = analyze_vad(
        analysis_wav,
        timeline_sample_count=timeline.sample_count,
        config=config.section("vad"),
        model_sha256=str(lock["sileroModelSHA256"]),
        package_version=str(lock["sileroVADVersion"]),
    )
    g2p_model = resolve_model_path(layout, "g2p")
    dictionary = build_merged_dictionary(
        base_dictionary=resolve_model_path(layout, "dictionary"),
        pronunciation_overrides=CONFIG_ROOT / "pronunciation_overrides.dict",
        transcript=transcript,
        g2p_model=g2p_model,
        destination=workspace / "english_us_arpa-merged.dict",
        extraction_root=workspace / "g2p-generation",
    )
    align_one(
        mfa=layout.mfa,
        analysis_wav=analysis_wav,
        transcript_path=transcript_path,
        output_path=alignment_path,
        temporary_directory=workspace / "mfa-temp",
        config_path=CONFIG_ROOT / "mfa_config.yaml",
        models=MFAModelPaths(
            acoustic_model=resolve_model_path(layout, "acoustic"),
            dictionary=dictionary.path,
            g2p_model=g2p_model,
        ),
        mfa_root_directory=layout.model_root,
    )
    alignment = parse_mfa_json(
        alignment_path,
        timeline_sample_count=timeline.sample_count,
        tolerance_ms=int(config.section("alignment")["phoneBoundaryToleranceMs"]),
    )
    alignment, _ = repair_boundary_absorbed_phones(
        alignment,
        vad.speech_spans,
        timeline_sample_count=timeline.sample_count,
        maximum_phone_samples=int(
            float(config.section("adjudication")["maximumPhoneDurationSeconds"]) * 48_000
        ),
    )
    validate_alignment_quality(
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
        speech_overlap_threshold=float(
            config.section("adjudication")["frameSpeechOverlapThreshold"]
        ),
    )
    frames = apply_coarticulation(
        frames,
        pose_map,
        silence_barrier_frames=int(config.section("coarticulation")["silenceBarrierFrames"]),
    )
    return VerbalCompilation(
        poses=[frame.pose.value for frame in frames],
        evidence=[frame.evidence_mask for frame in frames],
        transcript_sha256=transcript_sha,
        mfa_raw_output_sha256=sha256_file(alignment_path),
    )
