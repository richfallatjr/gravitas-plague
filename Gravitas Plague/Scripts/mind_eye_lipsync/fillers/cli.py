from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from ..config import CONFIG_ROOT, PROJECT_ROOT, RESOURCES_ROOT
from . import COMPILER_VERSION
from .bundle_audit import audit_bundle
from .inventory import inventory
from .nonverbal_analyzer import analyze, read_pcm16
from .pose_runs import POSE_BITS, compact
from .publisher import publish_set
from .registry import (REGISTRY_PATH, canonical_bytes, load_registry, sha256_bytes,
                       sha256_file, validate_registry, write_registry)
from .review import build_review, build_review_set
from .validator import load_and_validate_track, validate_set
from .verbal_compiler import compile_verbal_filler

DEFAULT_TARGET = RESOURCES_ROOT / "Turing" / "MindsEye" / "Fillers"


def _compile_clip(clip: dict, output: Path, toolchain_root: Path) -> dict:
    audio = RESOURCES_ROOT / clip["audioResourcePath"]
    ffmpeg = toolchain_root / "bin" / "ffmpeg"
    if not ffmpeg.is_file():
        ffmpeg = toolchain_root / "mfa" / "bin" / "ffmpeg"
    authoring = clip["authoring"]
    transcript_sha = None
    mfa_raw_output_sha = None
    with tempfile.TemporaryDirectory(prefix="mind-eye-filler.", dir=PROJECT_ROOT / ".build") as temp:
        workspace = Path(temp)
        wav = workspace / "timeline.wav"
        subprocess.run([str(ffmpeg), "-nostdin", "-v", "error", "-y",
                        "-i", str(audio), "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", str(wav)], check=True)
        samples, sample_count = read_pcm16(wav)
        frame_count = (sample_count + 799) // 800
        if authoring["mode"] == "manualTranscript":
            verbal = compile_verbal_filler(
                audio_source=audio,
                timeline_wav=wav,
                workspace=workspace,
                transcript_text=authoring["transcript"],
                toolchain_root=toolchain_root,
            )
            poses, evidence = verbal.poses, verbal.evidence
            transcript_sha = verbal.transcript_sha256
            mfa_raw_output_sha = verbal.mfa_raw_output_sha256
        else:
            poses, evidence = analyze(
                samples, frame_count, authoring["profile"], False
            )
    runs = compact(poses, evidence)
    expanded = bytes(POSE_BITS[pose] for pose in poses)
    descriptor_sha = sha256_bytes(canonical_bytes(clip))
    config_sha = sha256_file(CONFIG_ROOT / "compiler_config.json")
    phone_sha = sha256_file(CONFIG_ROOT / "phoneme_pose_map.json")
    lock_sha = sha256_file(Path(__file__).resolve().parents[1] / "toolchain" / "toolchain.lock.json")
    payload = {
        "schemaVersion": 1, "trackVersion": "mind-eye-filler-track/1",
        "compilerVersion": COMPILER_VERSION, "fillerID": clip["fillerID"],
        "speakerCharacterID": clip["speakerCharacterID"],
        "audioResourcePath": clip["audioResourcePath"], "audioSHA256": sha256_file(audio),
        "descriptorSHA256": descriptor_sha,
        "authoring": {"mode": authoring["mode"], "transcriptSHA256": transcript_sha,
                      "nonverbalProfile": authoring.get("profile")},
        "timeline": {"sampleRate": 48000, "sampleCount": sample_count,
                     "durationSeconds": round(sample_count / 48000.0, 9), "framesPerSecond": 60,
                     "samplesPerNominalFrame": 800, "frameCount": frame_count},
        "mouthLayerBits": POSE_BITS, "poseRuns": runs,
        "expandedFramesSHA256": hashlib.sha256(expanded).hexdigest(),
        "analysisProvenance": {"toolchainLockSHA256": lock_sha,
                               "compilerConfigSHA256": config_sha,
                               "phonemePoseMapSHA256": phone_sha,
                               "mfaRawOutputSHA256": mfa_raw_output_sha,
                               "nonverbalConfigurationSHA256": (
                                   None if authoring["mode"] == "manualTranscript"
                                   else sha256_bytes(b"mind-eye-filler-features/1\n")
                               )},
        "summary": {"poseFrameCounts": dict(Counter(poses)),
                    "speechFrameCount": sum(pose != "rest" for pose in poses),
                    "fallbackFrameCount": 0, "manualOverrideFrameCount": 0,
                    "warningCodes": []},
    }
    output.parent.mkdir(parents=True, exist_ok=True); output.write_bytes(canonical_bytes(payload))
    return payload


def compile_all(
    registry_path: Path,
    output: Path,
    toolchain_root: Path,
    *,
    report_directory: Path | None = None,
    resume_valid_verbal: bool = False,
) -> dict:
    registry = load_registry(registry_path)
    tracks = output / "Tracks"; tracks.mkdir(parents=True, exist_ok=True)
    entries = []
    for clip in registry["clips"]:
        path = tracks / f'{clip["fillerID"]}.fillerframes.json'
        if (resume_valid_verbal and clip["authoring"]["mode"] == "manualTranscript"
                and path.is_file()):
            track = json.loads(path.read_text(encoding="utf-8"))
        else:
            track = _compile_clip(clip, path, toolchain_root)
        entries.append({"fillerID": clip["fillerID"], "speakerCharacterID": clip["speakerCharacterID"],
                        "audioResourcePath": clip["audioResourcePath"], "audioSHA256": track["audioSHA256"],
                        "weight": clip["weight"], "authoringMode": clip["authoring"]["mode"],
                        "trackResourcePath": f'Turing/MindsEye/Fillers/Tracks/{path.name}',
                        "trackSHA256": sha256_file(path), "sampleRate": 48000,
                        "sampleCount": track["timeline"]["sampleCount"], "frameCount": track["timeline"]["frameCount"],
                        "durationSeconds": track["timeline"]["durationSeconds"], "poseRunCount": len(track["poseRuns"])})
    manifest_set_sha = sha256_bytes("\n".join(item["trackSHA256"] for item in entries).encode())
    unique = Counter(item["speakerCharacterID"] for item in entries); weighted = Counter()
    for item in entries: weighted[item["speakerCharacterID"]] += item["weight"]
    index = {"schemaVersion": 1, "indexVersion": "mind-eye-filler-index/1", "compilerVersion": COMPILER_VERSION,
             "registrySHA256": sha256_file(registry_path),
             "toolchainLockSHA256": sha256_file(Path(__file__).resolve().parents[1] / "toolchain" / "toolchain.lock.json"),
             "expectedUniqueClipCounts": registry["expectedUniqueClipCounts"],
             "expectedWeightedTotals": registry["expectedWeightedTotals"], "manifestSetSHA256": manifest_set_sha,
             "entries": entries,
             "summary": {"uniqueClipCount": len(entries), "weightedEntryCount": sum(weighted.values()),
                         "speakerUniqueCounts": dict(unique), "speakerWeightedTotals": dict(weighted),
                         "totalTrackBytes": sum((tracks / f'{item["fillerID"]}.fillerframes.json').stat().st_size for item in entries)}}
    (output / "index.json").write_bytes(canonical_bytes(index))
    if report_directory is not None:
        build_review_set(output, report_directory, toolchain_root)
    return index


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="command", required=True)
    for name in ("inventory", "write-registry-template", "validate-registry", "doctor"):
        command = sub.add_parser(name); command.add_argument("--json", action="store_true")
        if name == "write-registry-template": command.add_argument("--output", type=Path, required=True)
        if name == "validate-registry": command.add_argument("--registry", type=Path, default=REGISTRY_PATH)
    compile_one = sub.add_parser("compile")
    compile_one.add_argument("--registry", type=Path, default=REGISTRY_PATH)
    compile_one.add_argument("--filler-id", required=True)
    compile_one.add_argument("--output", type=Path, required=True)
    compile_one.add_argument("--report-directory", type=Path)
    compile_one.add_argument("--toolchain-root", type=Path, default=PROJECT_ROOT / ".mind-eye-toolchains")
    compile_parser = sub.add_parser("compile-all"); compile_parser.add_argument("--registry", type=Path, default=REGISTRY_PATH)
    compile_parser.add_argument("--output-directory", type=Path, required=True); compile_parser.add_argument("--report-directory", type=Path)
    compile_parser.add_argument("--expected-unique-count", type=int, default=51); compile_parser.add_argument("--jobs", type=int, default=1)
    compile_parser.add_argument("--toolchain-root", type=Path, default=PROJECT_ROOT / ".mind-eye-toolchains")
    compile_parser.add_argument("--resume-valid-verbal", action="store_true")
    validate_track_parser = sub.add_parser("validate-track")
    validate_track_parser.add_argument("--track", type=Path, required=True)
    validate_track_parser.add_argument("--json", action="store_true")
    validate = sub.add_parser("validate-set"); validate.add_argument("--directory", type=Path, required=True); validate.add_argument("--json", action="store_true")
    compare = sub.add_parser("compare-sets"); compare.add_argument("--left", type=Path, required=True); compare.add_argument("--right", type=Path, required=True); compare.add_argument("--json", action="store_true")
    review = sub.add_parser("build-review")
    review.add_argument("--directory", type=Path, required=True)
    review.add_argument("--output-directory", type=Path, required=True)
    review.add_argument("--toolchain-root", type=Path, default=PROJECT_ROOT / ".mind-eye-toolchains")
    review.add_argument("--json", action="store_true")
    publish = sub.add_parser("publish-set"); publish.add_argument("--candidate", type=Path, required=True); publish.add_argument("--target", type=Path, default=DEFAULT_TARGET); publish.add_argument("--json", action="store_true")
    bundle = sub.add_parser("audit-bundle")
    bundle.add_argument("--bundle", type=Path, required=True)
    bundle.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "inventory": result = inventory()
    elif args.command == "write-registry-template":
        template = write_registry(args.output)
        for clip in template["clips"]:
            clip["reviewStatus"] = "requiresHumanReview"
        args.output.write_bytes(canonical_bytes(template))
        validate_registry(template)
        result = {"status": "PASS", "output": str(args.output), "clips": len(template["clips"])}
    elif args.command == "validate-registry":
        registry = load_registry(args.registry)
        result = {"status": "PASS", "clips": len(registry["clips"])}
    elif args.command == "doctor":
        required = [
            PROJECT_ROOT / ".mind-eye-toolchains" / "mfa" / "bin" / "ffmpeg",
            PROJECT_ROOT / ".mind-eye-toolchains" / "mfa" / "bin" / "ffprobe",
            PROJECT_ROOT / ".mind-eye-toolchains" / "mfa" / "bin" / "mfa",
        ]
        if not all(path.is_file() for path in required): raise ValueError("Filler authoring toolchain is incomplete")
        result = {"status": "PASS", "runtimeAudioAnalysis": False, "serialAuthoringJobs": 1}
    elif args.command == "compile":
        registry = load_registry(args.registry)
        matches = [clip for clip in registry["clips"] if clip["fillerID"] == args.filler_id]
        if len(matches) != 1:
            raise ValueError(f"Unknown or ambiguous filler ID: {args.filler_id}")
        track = _compile_clip(matches[0], args.output, args.toolchain_root)
        load_and_validate_track(args.output)
        result = {"status": "PASS", "fillerID": args.filler_id, "output": str(args.output)}
        if args.report_directory is not None and track["authoring"]["mode"] == "nonverbal":
            result["review"] = build_review(
                args.output, args.report_directory, args.toolchain_root
            )
    elif args.command == "compile-all":
        if args.expected_unique_count != 51 or args.jobs != 1: raise ValueError("Filler authoring requires 51 clips and --jobs 1")
        result = compile_all(
            args.registry,
            args.output_directory,
            args.toolchain_root,
            report_directory=args.report_directory,
            resume_valid_verbal=args.resume_valid_verbal,
        )
    elif args.command == "validate-track":
        track = load_and_validate_track(args.track)
        result = {"status": "PASS", "fillerID": track["fillerID"], "frames": track["timeline"]["frameCount"]}
    elif args.command == "validate-set": result = validate_set(args.directory)
    elif args.command == "compare-sets":
        left = {path.relative_to(args.left): path.read_bytes() for path in args.left.rglob("*") if path.is_file()}
        right = {path.relative_to(args.right): path.read_bytes() for path in args.right.rglob("*") if path.is_file()}
        if left != right: raise ValueError("Filler candidate sets are not byte-identical")
        result = {"status": "PASS", "byteIdentical": True, "files": len(left)}
    elif args.command == "build-review":
        result = build_review_set(
            args.directory, args.output_directory, args.toolchain_root
        )
    elif args.command == "publish-set":
        result = publish_set(args.candidate, args.target)
    else:
        result = audit_bundle(args.bundle)
    print(json.dumps(result, ensure_ascii=False, indent=2)); return 0
