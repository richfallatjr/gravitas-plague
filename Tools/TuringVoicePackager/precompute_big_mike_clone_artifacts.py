#!/usr/bin/env python3
"""
Mac-only authoring tool for Turing Big Mike Qwen Base clone artifacts.

This script converts an existing .qwenclone profile shell containing:
  variants/<variantID>/ref_audio/normalized/ref_24000_mono.wav
  variants/<variantID>/ref_text.txt
into durable runtime artifacts:
  variants/<variantID>/qwen_artifacts/clone_artifacts.safetensors
  variants/<variantID>/qwen_artifacts/clone_prompt_manifest.json
  variants/<variantID>/qwen_artifacts/reference_codes.i32le
  variants/<variantID>/qwen_artifacts/speaker_embedding.f32le
  variants/<variantID>/qwen_artifacts/ref_text_tokens.i32le
  variants/<variantID>/qwen_artifacts/checksums.sha256

It is intentionally Mac/offline only. Do not ship this script, qwen-tts, torch, or
its environment inside the visionOS app bundle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional, Tuple


def fail(message: str, code: int = 2) -> None:
    print(f"[TuringVoicePackager] ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_checksums(path: Path, root: Path, files: list[Path]) -> None:
    lines: list[str] = []
    for file in sorted(files):
        if not file.exists() or not file.is_file():
            continue
        lines.append(f"{sha256_file(file)}  {file.relative_to(root).as_posix()}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def resolve_profile_root(repo_root: Path, explicit: Optional[str]) -> Path:
    if explicit:
        profile = Path(explicit).expanduser()
        if not profile.is_absolute():
            profile = repo_root / profile
        return profile
    return repo_root / "Gravitas Plague" / "TuringResources" / "Turing" / "Voices" / "Cloned" / "BigMike" / "BaseClone" / "big_mike_base_clone_v1.qwenclone"


def resolve_authoring_model(repo_root: Path, model_arg: str, allow_download: bool) -> str:
    # Local directory is preferred and required unless an explicit HF repo id is allowed.
    p = Path(model_arg).expanduser()
    if not p.is_absolute():
        p = repo_root / p
    if p.exists():
        return str(p)

    looks_like_repo = "/" in model_arg and not model_arg.startswith("/") and not model_arg.startswith(".")
    if looks_like_repo:
        if not allow_download:
            fail(
                "Authoring model path does not exist and model argument looks like a Hugging Face repo ID. "
                "Pass --allow-model-download explicitly, or download the official PyTorch Base model to a local authoring path first. "
                f"model={model_arg}"
            )
        return model_arg

    fail(
        f"Authoring model path does not exist: {p}\n"
        "This Mac-only precompute step requires the official Qwen Base authoring model, not the MLX 4-bit runtime folder."
    )


def pick_device_and_dtype(device: str, dtype: str) -> Tuple[str, str]:
    try:
        import torch  # type: ignore
    except Exception as exc:
        fail(f"Could not import torch. Activate the authoring venv first. {exc}")

    resolved_device = device
    if device == "auto":
        if torch.cuda.is_available():
            resolved_device = "cuda:0"
        elif getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
            resolved_device = "mps"
        else:
            resolved_device = "cpu"

    resolved_dtype = dtype
    if dtype == "auto":
        if resolved_device.startswith("cuda"):
            resolved_dtype = "bfloat16"
        else:
            # CPU/MPS authoring is slower and memory-hungry, but float32 is safer than guessing bf16 support.
            resolved_dtype = "float32"

    return resolved_device, resolved_dtype


def torch_dtype_from_name(name: str):
    import torch  # type: ignore
    table = {
        "float32": torch.float32,
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
    }
    if name not in table:
        fail(f"Unsupported dtype: {name}. Use auto, float32, float16, or bfloat16.")
    return table[name]


def tensor_to_numpy_cpu(tensor: Any):
    # Keep imports local so CLI validation can run before qwen deps are loaded.
    return tensor.detach().to("cpu").contiguous().numpy()


def main() -> None:
    ap = argparse.ArgumentParser(description="Precompute Big Mike Qwen Base clone artifacts from a .qwenclone profile.")
    ap.add_argument("--root", required=True, help="Repo root, e.g. /Users/.../gravitas-plague")
    ap.add_argument("--profile", default=None, help="Path to big_mike_base_clone_v1.qwenclone. Defaults to repo TuringResources path.")
    ap.add_argument("--variant-id", default="broadcast_reading_lazy")
    ap.add_argument(
        "--authoring-model",
        default="Authoring/Models/Qwen3-TTS-12Hz-1.7B-Base",
        help="Local official PyTorch Qwen Base model directory, or Qwen/Qwen3-TTS-12Hz-1.7B-Base with --allow-model-download.",
    )
    ap.add_argument("--allow-model-download", action="store_true", help="Allow qwen-tts/transformers to resolve a HF repo ID. Never used by the app.")
    ap.add_argument("--device", default="auto", help="auto, cuda:0, mps, or cpu")
    ap.add_argument("--dtype", default="auto", help="auto, float32, float16, bfloat16")
    ap.add_argument("--x-vector-only", action="store_true", help="Create speaker-embedding-only prompt. Default is ICL/full ref_code mode.")
    ap.add_argument("--write-smoke-wav", action="store_true", help="Optional Mac-only verification WAV using official Qwen generate_voice_clone.")
    ap.add_argument("--smoke-text", default="Rich, listen to me. Stay away from the window.")
    ap.add_argument("--language", default="English")
    args = ap.parse_args()

    repo_root = Path(args.root).expanduser().resolve()
    if not repo_root.exists():
        fail(f"Repo root does not exist: {repo_root}")

    profile_root = resolve_profile_root(repo_root, args.profile).resolve()
    variant_root = profile_root / "variants" / args.variant_id
    ref_wav = variant_root / "ref_audio" / "normalized" / "ref_24000_mono.wav"
    ref_text_path = variant_root / "ref_text.txt"
    metadata_path = profile_root / "metadata.json"
    variant_json_path = variant_root / "variant.json"

    for path, label in [
        (profile_root, "profile root"),
        (variant_root, "variant root"),
        (ref_wav, "normalized reference WAV"),
        (ref_text_path, "reference text"),
        (metadata_path, "profile metadata"),
        (variant_json_path, "variant metadata"),
    ]:
        if not path.exists():
            fail(f"Missing {label}: {path}")

    ref_text = ref_text_path.read_text(encoding="utf-8").strip()
    if not ref_text:
        fail(f"Reference text is empty: {ref_text_path}")

    model_arg = resolve_authoring_model(repo_root, args.authoring_model, args.allow_model_download)
    device, dtype_name = pick_device_and_dtype(args.device, args.dtype)

    print("[TuringVoicePackager] Base clone artifact precompute starting")
    print(f"  profile: {profile_root}")
    print(f"  variantID: {args.variant_id}")
    print(f"  refWav: {ref_wav}")
    print(f"  refTextUTF8: {len(ref_text.encode('utf-8'))}")
    print(f"  authoringModel: {model_arg}")
    print(f"  device: {device}")
    print(f"  dtype: {dtype_name}")
    print(f"  xVectorOnly: {args.x_vector_only}")

    try:
        import numpy as np  # type: ignore
        import torch  # type: ignore
        from safetensors.torch import save_file  # type: ignore
        from qwen_tts import Qwen3TTSModel  # type: ignore
    except Exception as exc:
        fail(
            "Missing authoring dependencies. Install in a Mac-only venv, e.g. "
            "python3 -m venv .venv-qwen-author && source .venv-qwen-author/bin/activate && "
            "pip install -U qwen-tts safetensors soundfile librosa numpy torch. "
            f"Import error: {exc}"
        )

    dtype = torch_dtype_from_name(dtype_name)
    load_kwargs: Dict[str, Any] = {"dtype": dtype}
    # Hugging Face/Transformers accepts device_map for cuda/cpu. MPS support varies; try direct device_map first.
    if device in {"cpu", "mps"} or device.startswith("cuda"):
        load_kwargs["device_map"] = device
    if device.startswith("cuda"):
        # Flash attention may not be installed; do not require it unless caller env supports it.
        load_kwargs.setdefault("attn_implementation", "flash_attention_2")

    try:
        model = Qwen3TTSModel.from_pretrained(model_arg, **load_kwargs)
    except Exception as exc:
        fail(f"Could not load official Qwen Base authoring model. model={model_arg} device={device} dtype={dtype_name}. Error: {exc}")

    tts_type = getattr(model.model, "tts_model_type", None)
    if tts_type != "base":
        fail(f"Authoring model is not Base. tts_model_type={tts_type}")

    try:
        prompt_items = model.create_voice_clone_prompt(
            ref_audio=str(ref_wav),
            ref_text=None if args.x_vector_only else ref_text,
            x_vector_only_mode=bool(args.x_vector_only),
        )
    except Exception as exc:
        fail(f"create_voice_clone_prompt failed for variant {args.variant_id}: {exc}")

    if len(prompt_items) != 1:
        fail(f"Expected one VoiceClonePromptItem, got {len(prompt_items)}")
    item = prompt_items[0]

    artifacts_dir = variant_root / "qwen_artifacts"
    if artifacts_dir.exists():
        shutil.rmtree(artifacts_dir)
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    # Convert and save artifacts. Base ICL mode uses ref_code + speaker embedding.
    tensors_for_safetensors: Dict[str, Any] = {}

    ref_code_shape = None
    ref_code_dtype = None
    ref_code_bin = None
    if item.ref_code is not None:
        ref_code_cpu = item.ref_code.detach().to("cpu").contiguous()
        ref_code_np = ref_code_cpu.numpy()
        # Runtime wants i32 unless Swift path explicitly supports i64. Preserve shape in manifest.
        ref_code_i32 = ref_code_np.astype("<i4", copy=False)
        ref_code_bin = artifacts_dir / "reference_codes.i32le"
        ref_code_i32.tofile(ref_code_bin)
        ref_code_shape = list(ref_code_i32.shape)
        ref_code_dtype = "int32"
        tensors_for_safetensors["ref_code"] = ref_code_cpu.to(torch.int32)

    spk = item.ref_spk_embedding.detach().to("cpu").contiguous()
    spk_np = spk.numpy().astype("<f4", copy=False)
    spk_bin = artifacts_dir / "speaker_embedding.f32le"
    spk_np.tofile(spk_bin)
    tensors_for_safetensors["ref_spk_embedding"] = spk.to(torch.float32)

    # Ref-text token IDs are useful for Swift prompt parity and debugging.
    ref_text_tokens_shape = None
    ref_text_tokens_bin = None
    if not args.x_vector_only:
        try:
            ref_ids = model._tokenize_texts([model._build_ref_text(ref_text)])[0].detach().to("cpu").contiguous()
            ref_ids_np = ref_ids.numpy().astype("<i4", copy=False)
            ref_text_tokens_bin = artifacts_dir / "ref_text_tokens.i32le"
            ref_ids_np.tofile(ref_text_tokens_bin)
            ref_text_tokens_shape = list(ref_ids_np.shape)
            tensors_for_safetensors["ref_text_tokens"] = ref_ids.to(torch.int32)
        except Exception as exc:
            fail(f"Could not tokenize ref_text with official processor: {exc}")

    safetensors_path = artifacts_dir / "clone_artifacts.safetensors"
    try:
        save_file(tensors_for_safetensors, str(safetensors_path))
    except Exception as exc:
        fail(f"Could not save clone_artifacts.safetensors: {exc}")

    smoke_wav_path = None
    smoke_metrics = None
    if args.write_smoke_wav:
        try:
            wavs, sr = model.generate_voice_clone(
                text=args.smoke_text,
                language=args.language,
                voice_clone_prompt=prompt_items,
                max_new_tokens=256,
            )
            import soundfile as sf  # type: ignore
            smoke_wav_path = artifacts_dir / "mac_authoring_smoke.wav"
            sf.write(smoke_wav_path, wavs[0], sr)
            wav_np = np.asarray(wavs[0], dtype=np.float32)
            smoke_metrics = {
                "sampleRate": int(sr),
                "sampleCount": int(wav_np.size),
                "peakAbs": float(np.max(np.abs(wav_np))) if wav_np.size else 0.0,
                "rms": float(np.sqrt(np.mean(wav_np * wav_np))) if wav_np.size else 0.0,
                "text": args.smoke_text,
            }
            write_json(artifacts_dir / "mac_authoring_smoke_metrics.json", smoke_metrics)
        except Exception as exc:
            fail(f"Optional generate_voice_clone smoke WAV failed: {exc}")

    manifest = {
        "schemaVersion": 1,
        "artifactKind": "qwen3_tts_base_voice_clone_prompt",
        "voiceID": "big_mike_base_clone_v1",
        "variantID": args.variant_id,
        "mode": "x_vector" if args.x_vector_only else "icl",
        "xVectorOnlyMode": bool(args.x_vector_only),
        "iclMode": bool(not args.x_vector_only),
        "createdOn": platform.node(),
        "createdBy": "Tools/TuringVoicePackager/precompute_big_mike_clone_artifacts.py",
        "pythonVersion": sys.version,
        "platform": platform.platform(),
        "authoringModel": str(model_arg),
        "runtimeModelID": "qwen3-tts-12hz-1.7b-base-4bit",
        "runtimeQuantization": "4bit",
        "language": args.language,
        "reference": {
            "audioPath": os.path.relpath(ref_wav, artifacts_dir),
            "audioSHA256": sha256_file(ref_wav),
            "textPath": os.path.relpath(ref_text_path, artifacts_dir),
            "textSHA256": sha256_text(ref_text),
            "textUTF8Bytes": len(ref_text.encode("utf-8")),
        },
        "artifacts": {
            "safetensors": "clone_artifacts.safetensors",
            "referenceCodes": None if ref_code_bin is None else ref_code_bin.name,
            "referenceCodesShape": ref_code_shape,
            "referenceCodesDType": ref_code_dtype,
            "speakerEmbedding": spk_bin.name,
            "speakerEmbeddingShape": list(spk_np.shape),
            "speakerEmbeddingDType": "float32",
            "refTextTokens": None if ref_text_tokens_bin is None else ref_text_tokens_bin.name,
            "refTextTokensShape": ref_text_tokens_shape,
            "refTextTokensDType": None if ref_text_tokens_bin is None else "int32",
        },
        "officialSemantics": {
            "sourceAPI": "Qwen3TTSModel.create_voice_clone_prompt(ref_audio, ref_text, x_vector_only_mode=False)",
            "runtimeAPIEquivalent": "Qwen3TTSModel.generate_voice_clone(text, language, voice_clone_prompt=prompt_items)",
            "decodeRule": "decode ref_code + generated_codes, then trim waveform proportionally by ref_code row count",
        },
    }
    write_json(artifacts_dir / "clone_prompt_manifest.json", manifest)

    checksum_files = [safetensors_path, artifacts_dir / "clone_prompt_manifest.json", spk_bin]
    if ref_code_bin is not None:
        checksum_files.append(ref_code_bin)
    if ref_text_tokens_bin is not None:
        checksum_files.append(ref_text_tokens_bin)
    if smoke_wav_path is not None:
        checksum_files.append(smoke_wav_path)
        checksum_files.append(artifacts_dir / "mac_authoring_smoke_metrics.json")
    write_checksums(artifacts_dir / "checksums.sha256", artifacts_dir, checksum_files)

    # Stamp the variant metadata so the app can fail fast if artifacts are stale/missing.
    try:
        variant = json.loads(variant_json_path.read_text(encoding="utf-8"))
    except Exception:
        variant = {}
    variant.setdefault("schemaVersion", 1)
    variant["qwenArtifacts"] = {
        "status": "ready",
        "path": "qwen_artifacts/clone_prompt_manifest.json",
        "mode": manifest["mode"],
        "safetensorsSHA256": sha256_file(safetensors_path),
        "manifestSHA256": sha256_file(artifacts_dir / "clone_prompt_manifest.json"),
    }
    write_json(variant_json_path, variant)

    print("[TuringVoicePackager] Base clone artifact precompute finished")
    print(f"  artifacts: {artifacts_dir}")
    print(f"  cloneManifest: {artifacts_dir / 'clone_prompt_manifest.json'}")
    print(f"  safetensors: {safetensors_path}")
    if ref_code_shape is not None:
        print(f"  refCodeShape: {ref_code_shape}")
    print(f"  speakerEmbeddingShape: {list(spk_np.shape)}")
    if ref_text_tokens_shape is not None:
        print(f"  refTextTokensShape: {ref_text_tokens_shape}")
    if smoke_metrics is not None:
        print(f"  smokeWav: {smoke_wav_path}")
        print(f"  smokePeakAbs: {smoke_metrics['peakAbs']}")
        print(f"  smokeRMS: {smoke_metrics['rms']}")


if __name__ == "__main__":
    main()
