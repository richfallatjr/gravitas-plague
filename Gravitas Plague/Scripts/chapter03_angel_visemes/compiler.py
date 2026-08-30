from __future__ import annotations

from dataclasses import replace
import json
import os
from pathlib import Path
import shutil
import subprocess
from typing import Any, Sequence

from mind_eye_lipsync.audio_decode import decode_wav
from mind_eye_lipsync.config import load_compiler_configuration
from mind_eye_lipsync.constants import MouthPose, POSE_TO_BIT, REQUIRED_POSES
from mind_eye_lipsync.deterministic_json import canonical_json_bytes, write_atomic_json
from mind_eye_lipsync.frame_expander import FrameDecision, apply_coarticulation, expand_frames
from mind_eye_lipsync.hashing import deterministic_tree_sha256, sha256_bytes, sha256_file
from mind_eye_lipsync.mfa_json import PhoneInterval, normalize_arpa_phone
from mind_eye_lipsync.phones import load_phone_pose_map, map_phone_intervals
from mind_eye_lipsync.timeline import parse_pcm_wav
from mind_eye_lipsync.vad import analyze_vad

from . import COMPILER_VERSION


SCRIPTS_ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = SCRIPTS_ROOT.parent
REPOSITORY_ROOT = PROJECT_DIR.parent
RESOURCE_ROOT = PROJECT_DIR / "TuringResources"
BUILD_ROOT = REPOSITORY_ROOT / ".build" / "chapter03-angel-visemes"
TOOLCHAIN_LOCK = SCRIPTS_ROOT / "mind_eye_lipsync" / "toolchain" / "toolchain.lock.json"
PHONE_MAP = SCRIPTS_ROOT / "mind_eye_lipsync" / "config" / "phoneme_pose_map.json"
RUNTIME_MODELS = RESOURCE_ROOT / "Turing" / "RuntimeLipSync" / "pocketsphinx-5.1.1" / "en-us"
DEFAULT_DESCRIPTOR = RESOURCE_ROOT / "Turing" / "Cinematics" / "Chapter03" / "pr_angel_01.json"
DEFAULT_OUTPUT = RESOURCE_ROOT / "Turing" / "Cinematics" / "Chapter03" / "Cues" / (
    "chapter03.cinematic.angel.lightTunnel.001.visemes.json"
)
TRACK_ID = "chapter03.cinematic.angel.lightTunnel.001.visemes"
CINEMATIC_ID = "chapter03.cinematic.angel.lightTunnel.001"
DESCRIPTOR_RESOURCE_PATH = "Turing/Cinematics/Chapter03/pr_angel_01.json"
POSE_MULTIPLIERS = {"rest": 1.0, "small": 1.33, "wide": 2.0, "round": 1.5, "teeth": 1.75}
SPECIAL_SILENCE = frozenset({"SIL", "<SIL>", "<EPS>", "+SPN+", "+NSN+", "+BR+"})


def _resolve(path: Path) -> Path:
    return path if path.is_absolute() else (PROJECT_DIR / path).resolve()


def _allphone_helper() -> Path:
    helper = BUILD_ROOT / "pocketsphinx-host-allphone"
    if not helper.is_file():
        subprocess.run(
            [str(SCRIPTS_ROOT / "runtime_lipsync" / "build_pocketsphinx_host_allphone.sh")],
            check=True,
        )
    return helper


def _run_allphone(analysis_wav: Path, output: Path) -> dict[str, Any]:
    subprocess.run([
        str(_allphone_helper()),
        str(RUNTIME_MODELS / "acoustic"),
        str(RUNTIME_MODELS / "cmudict-en-us.dict"),
        str(RUNTIME_MODELS / "en-us-phone.lm.bin"),
        str(analysis_wav),
        str(output),
    ], check=True)
    payload = json.loads(output.read_text(encoding="utf-8"))
    if (
        payload.get("schemaVersion") != 1
        or payload.get("engine") != "pocketsphinx"
        or payload.get("engineVersion") != "5.1.1"
        or payload.get("frameRate") != 100
        or not payload.get("phones")
    ):
        raise ValueError("Pinned PocketSphinx helper returned an invalid timeline")
    return payload


def _phone_intervals(payload: dict[str, Any], sample_count: int) -> tuple[PhoneInterval, ...]:
    intervals: list[PhoneInterval] = []
    for item in payload["phones"]:
        raw = str(item["phone"]).strip().upper()
        start_frame = int(item["startFrame"])
        duration = int(item["durationFrames"])
        if start_frame < 0 or duration <= 0:
            raise ValueError("PocketSphinx returned an invalid phone interval")
        start = min(sample_count, start_frame * 480)
        end = min(sample_count, (start_frame + duration) * 480)
        if end <= start:
            continue
        mapped_raw = "sil" if raw in SPECIAL_SILENCE else raw
        intervals.append(PhoneInterval(
            raw_phone=mapped_raw,
            normalized_phone=normalize_arpa_phone(mapped_raw),
            start_sample=start,
            end_sample=end,
            word_index=None,
        ))
    intervals.sort(key=lambda interval: (interval.start_sample, interval.end_sample))
    for previous, current in zip(intervals, intervals[1:]):
        if current.start_sample < previous.end_sample:
            raise ValueError("PocketSphinx phone intervals overlap")
    if not intervals:
        raise ValueError("PocketSphinx phone timeline mapped to no samples")
    return tuple(intervals)


def _force_nonspeech_to_rest(frames: Sequence[FrameDecision]) -> tuple[FrameDecision, ...]:
    return tuple(
        frame if frame.speech_active else replace(
            frame,
            pose=MouthPose.REST,
            layer_mask=POSE_TO_BIT[MouthPose.REST],
            source_phone="sil",
        )
        for frame in frames
    )


def _runs(frames: Sequence[FrameDecision]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    start = 0
    for index in range(1, len(frames) + 1):
        if index == len(frames) or frames[index].pose != frames[start].pose:
            result.append({
                "startFrame": start,
                "endFrameExclusive": index,
                "pose": frames[start].pose.value,
            })
            start = index
    return result


def _compact_runs_hash(runs: list[dict[str, Any]]) -> str:
    encoded = json.dumps(
        runs, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return sha256_bytes(encoded)


def _quality(frames: Sequence[FrameDecision], unknown_count: int, phone_count: int) -> dict[str, Any]:
    speech = [frame for frame in frames if frame.speech_active]
    nonrest_speech = [frame for frame in speech if frame.pose is not MouthPose.REST]
    nonspeech_nonrest = [frame for frame in frames if not frame.speech_active and frame.pose is not MouthPose.REST]
    speech_overlap = len(nonrest_speech) / max(len(speech), 1)
    speech_poses = {frame.pose for frame in nonrest_speech}
    runs = _runs(frames)
    transition_rate = max(0, len(runs) - 1) / max(len(frames) / 60.0, 1e-9)
    unknown_ratio = unknown_count / max(phone_count, 1)
    failures: list[str] = []
    if speech_overlap < 0.90: failures.append("non-rest overlap with VAD speech is below 90%")
    if nonspeech_nonrest: failures.append("non-rest pose exists outside VAD speech")
    if unknown_ratio > 0.01: failures.append("unknown phone ratio exceeds 1%")
    if len(speech_poses) < 3: failures.append("fewer than three pose families appear during speech")
    if MouthPose.WIDE not in speech_poses: failures.append("wide never appears during speech")
    if not any(frame.pose is MouthPose.REST for frame in frames): failures.append("rest never appears")
    if transition_rate > 15: failures.append("transition rate exceeds 15 per second")
    if failures:
        raise ValueError("; ".join(failures))
    return {
        "speechFrameCount": len(speech),
        "nonRestSpeechFrameCount": len(nonrest_speech),
        "nonRestSpeechOverlap": speech_overlap,
        "nonVADNonRestFrameCount": len(nonspeech_nonrest),
        "speechPoseFamilies": sorted(pose.value for pose in speech_poses),
        "unknownPhoneRatio": unknown_ratio,
        "transitionRatePerSecond": transition_rate,
    }


def _write_review_svg(path: Path, frames: Sequence[FrameDecision]) -> None:
    colors = {"rest": "#11121c", "small": "#582c83", "wide": "#d200ff", "round": "#008cff", "teeth": "#00f1ff"}
    width, height = 1200, 210
    bars = []
    total = max(len(frames), 1)
    for run in _runs(frames):
        x = run["startFrame"] * width / total
        run_width = (run["endFrameExclusive"] - run["startFrame"]) * width / total
        pose = run["pose"]
        multiplier = POSE_MULTIPLIERS[pose]
        bar_height = 30 + (multiplier - 1) * 85
        bars.append(
            f'<rect x="{x:.3f}" y="{155-bar_height:.3f}" width="{max(run_width, .25):.3f}" '
            f'height="{bar_height:.3f}" fill="{colors[pose]}"/>'
        )
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">'
        '<rect width="100%" height="100%" fill="#05050b"/>'
        '<text x="18" y="24" fill="white" font-family="monospace" font-size="16">Angel visemes / 30–60 embers per second</text>'
        + "".join(bars)
        + '<line x1="0" y1="155" x2="1200" y2="155" stroke="#666"/>'
        + '<text x="18" y="190" fill="#aaa" font-family="monospace" font-size="13">rest 30 | small 39.9 | round 45 | teeth 52.5 | wide 60</text>'
        + '</svg>\n'
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg, encoding="utf-8")


def build(
    descriptor_path: Path,
    output_path: Path,
    review_json: Path | None,
    review_svg: Path | None,
    force: bool,
) -> dict[str, Any]:
    descriptor_path, output_path = _resolve(descriptor_path), _resolve(output_path)
    if output_path.exists() and not force:
        raise FileExistsError(f"Refusing to replace {output_path}; pass --force")
    descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
    if (
        descriptor.get("id") != CINEMATIC_ID
        or descriptor.get("transcriptMode") != "none"
        or str(descriptor.get("transcript", "")).strip()
    ):
        raise ValueError("Current Angel source must use transcript-free all-phone alignment")
    audio_resource_path = str(descriptor["audioFile"])
    audio_path = RESOURCE_ROOT / audio_resource_path
    if not audio_path.is_file(): raise FileNotFoundError(audio_path)

    workspace = BUILD_ROOT / "work"
    if workspace.exists(): shutil.rmtree(workspace)
    workspace.mkdir(parents=True)
    timeline_wav = workspace / "timeline-48000.wav"
    analysis_wav = workspace / "analysis-16000.wav"
    allphone_json = workspace / "allphone.json"
    ffmpeg = Path(shutil.which("ffmpeg") or "")
    if not ffmpeg.is_file(): raise RuntimeError("ffmpeg is unavailable")
    decode_wav(ffmpeg, audio_path, timeline_wav, sample_rate=48_000)
    timeline = parse_pcm_wav(timeline_wav)
    decode_wav(ffmpeg, timeline_wav, analysis_wav, sample_rate=16_000)
    allphone = _run_allphone(analysis_wav, allphone_json)

    lock = json.loads(TOOLCHAIN_LOCK.read_text(encoding="utf-8"))
    config = load_compiler_configuration()
    # The pinned environment currently contains two OpenMP-linked authoring packages.
    # This is authoring-only and forces the same single-thread Silero execution used by the existing compiler.
    os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
    os.environ.setdefault("OMP_NUM_THREADS", "1")
    vad = analyze_vad(
        analysis_wav,
        timeline_sample_count=timeline.sample_count,
        config=config.section("vad"),
        model_sha256=str(lock["sileroModelSHA256"]),
        package_version=str(lock["sileroVADVersion"]),
    )
    phones = _phone_intervals(allphone, timeline.sample_count)
    mapping_config = load_phone_pose_map(PHONE_MAP)
    mapping = map_phone_intervals(phones, vad.speech_spans, mapping_config)
    frames = expand_frames(
        timeline,
        mapping.spans,
        vad.speech_spans,
        speech_overlap_threshold=float(config.section("adjudication")["frameSpeechOverlapThreshold"]),
    )
    frames = apply_coarticulation(
        frames,
        mapping_config,
        silence_barrier_frames=int(config.section("coarticulation")["silenceBarrierFrames"]),
    )
    frames = _force_nonspeech_to_rest(frames)
    quality = _quality(frames, len(mapping.fallback_phones), len(phones))
    runs = _runs(frames)
    counts = {pose.value: 0 for pose in REQUIRED_POSES}
    for run in runs:
        counts[run["pose"]] += run["endFrameExclusive"] - run["startFrame"]

    manifest = {
        "schemaVersion": 1,
        "compilerVersion": COMPILER_VERSION,
        "trackID": TRACK_ID,
        "sourceCinematicID": CINEMATIC_ID,
        "descriptorResourcePath": DESCRIPTOR_RESOURCE_PATH,
        "descriptorSHA256": sha256_file(descriptor_path),
        "audioResourcePath": audio_resource_path,
        "audioSHA256": sha256_file(audio_path),
        "timeline": {
            "sampleRate": timeline.sample_rate,
            "sampleCount": timeline.sample_count,
            "durationSeconds": timeline.duration_seconds,
            "framesPerSecond": timeline.frames_per_second,
            "samplesPerNominalFrame": timeline.samples_per_nominal_frame,
            "frameCount": timeline.frame_count,
        },
        "requiredPoseFamilies": [pose.value for pose in REQUIRED_POSES],
        "densityMultipliers": POSE_MULTIPLIERS,
        "alignment": {
            "mode": "pocketsphinxAllPhone",
            "engine": "pocketsphinx",
            "engineVersion": "5.1.1",
            "acousticModelSHA256": deterministic_tree_sha256(RUNTIME_MODELS / "acoustic"),
            "phoneLanguageModelSHA256": sha256_file(RUNTIME_MODELS / "en-us-phone.lm.bin"),
            "transcriptSHA256": None,
            "VADModelSHA256": str(lock["sileroModelSHA256"]),
            "phonePoseMapSHA256": sha256_file(PHONE_MAP),
        },
        "runsSHA256": _compact_runs_hash(runs),
        "runs": runs,
        "summary": {
            "poseFrameCounts": counts,
            "speechFrameCount": timeline.frame_count - counts["rest"],
            "silenceFrameCount": counts["rest"],
            "unknownPhoneCount": len(mapping.fallback_phones),
            "runCount": len(runs),
            "warnings": list(mapping.warnings),
        },
    }
    write_atomic_json(output_path, manifest)
    review = {"schemaVersion": 1, "quality": quality, "phoneCount": len(phones), "runs": runs}
    if review_json: write_atomic_json(_resolve(review_json), review)
    if review_svg: _write_review_svg(_resolve(review_svg), frames)
    return manifest


def validate(path: Path = DEFAULT_OUTPUT, verify_sources: bool = False) -> dict[str, Any]:
    path = _resolve(path)
    manifest = json.loads(path.read_text(encoding="utf-8"))
    required = [pose.value for pose in REQUIRED_POSES]
    timeline, runs, summary = manifest["timeline"], manifest["runs"], manifest["summary"]
    expected_frames = (int(timeline["sampleCount"]) + 799) // 800
    if (
        manifest.get("schemaVersion") != 1
        or manifest.get("compilerVersion") != COMPILER_VERSION
        or manifest.get("trackID") != TRACK_ID
        or manifest.get("sourceCinematicID") != CINEMATIC_ID
        or timeline.get("sampleRate") != 48000
        or timeline.get("framesPerSecond") != 60
        or timeline.get("samplesPerNominalFrame") != 800
        or timeline.get("frameCount") != expected_frames
        or manifest.get("requiredPoseFamilies") != required
        or manifest.get("densityMultipliers") != POSE_MULTIPLIERS
        or not runs
        or manifest.get("runsSHA256") != _compact_runs_hash(runs)
    ):
        raise ValueError("Angel viseme manifest contract is invalid")
    cursor, previous = 0, None
    counts = {pose: 0 for pose in required}
    for run in runs:
        if run["startFrame"] != cursor or run["endFrameExclusive"] <= cursor or run["pose"] == previous:
            raise ValueError("Angel viseme runs are invalid")
        counts[run["pose"]] += run["endFrameExclusive"] - run["startFrame"]
        cursor, previous = run["endFrameExclusive"], run["pose"]
    if cursor != expected_frames or summary["poseFrameCounts"] != counts or summary["runCount"] != len(runs):
        raise ValueError("Angel viseme summary is invalid")
    if verify_sources:
        descriptor = RESOURCE_ROOT / manifest["descriptorResourcePath"]
        audio = RESOURCE_ROOT / manifest["audioResourcePath"]
        if sha256_file(descriptor) != manifest["descriptorSHA256"] or sha256_file(audio) != manifest["audioSHA256"]:
            raise ValueError("Angel source hashes are stale")
        if deterministic_tree_sha256(RUNTIME_MODELS / "acoustic") != manifest["alignment"]["acousticModelSHA256"]:
            raise ValueError("Angel acoustic model hash is stale")
        if sha256_file(RUNTIME_MODELS / "en-us-phone.lm.bin") != manifest["alignment"]["phoneLanguageModelSHA256"]:
            raise ValueError("Angel phone language model hash is stale")
        if sha256_file(PHONE_MAP) != manifest["alignment"]["phonePoseMapSHA256"]:
            raise ValueError("Angel phone-pose map hash is stale")
    return manifest
