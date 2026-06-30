#!/usr/bin/env python3
"""
Mac-only Turing Qwen Base clone artifact precompute.

This script does not generate story speech. It converts a reference clip + exact
transcript into reusable Qwen Base clone-conditioning artifacts for the visionOS
runtime.

It intentionally fails loudly if the installed qwen-tts API shape changes or if
required artifacts cannot be found in create_voice_clone_prompt(...).
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from typing import Any, Iterable


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def repo_git_commit(path: pathlib.Path) -> str | None:
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return None


def to_numpy(value: Any):
    import numpy as np

    # torch tensor
    if hasattr(value, "detach") and hasattr(value, "cpu") and hasattr(value, "numpy"):
        return value.detach().cpu().numpy()
    # mlx / other arrays often expose numpy through __array__
    try:
        arr = np.asarray(value)
        if arr.dtype != object and arr.size > 0:
            return arr
    except Exception:
        pass
    return None


def flatten_named(obj: Any, prefix: str = "") -> list[tuple[str, Any]]:
    """Return best-effort dotted field names for prompt object inspection."""
    out: list[tuple[str, Any]] = []
    seen: set[int] = set()

    def rec(x: Any, name: str, depth: int) -> None:
        if depth > 8:
            return
        xid = id(x)
        if xid in seen:
            return
        seen.add(xid)
        out.append((name, x))

        if dataclasses.is_dataclass(x):
            for f in dataclasses.fields(x):
                try:
                    rec(getattr(x, f.name), f"{name}.{f.name}" if name else f.name, depth + 1)
                except Exception:
                    pass
            return
        if isinstance(x, dict):
            for k, v in x.items():
                rec(v, f"{name}.{k}" if name else str(k), depth + 1)
            return
        if isinstance(x, (list, tuple)):
            for i, v in enumerate(x):
                rec(v, f"{name}[{i}]" if name else f"[{i}]", depth + 1)
            return
        if hasattr(x, "__dict__"):
            for k, v in vars(x).items():
                if k.startswith("_"):
                    continue
                rec(v, f"{name}.{k}" if name else k, depth + 1)

    rec(obj, prefix, 0)
    return out


def choose_arrays(prompt_items: Any) -> tuple[Any, Any, Any | None, dict[str, Any]]:
    import numpy as np

    named = flatten_named(prompt_items)
    trace: dict[str, Any] = {"fields": []}
    arrays: list[tuple[str, Any, Any]] = []
    for name, value in named:
        arr = to_numpy(value)
        if arr is not None:
            arrays.append((name, value, arr))
            trace["fields"].append({
                "name": name,
                "shape": list(arr.shape),
                "dtype": str(arr.dtype),
                "kind": "array",
            })
        elif isinstance(value, (str, int, float, bool, type(None))):
            trace["fields"].append({"name": name, "value": value, "kind": type(value).__name__})

    def score_code(item: tuple[str, Any, Any]) -> int:
        name, _, arr = item
        n = name.lower()
        score = 0
        if "ref_code" in n: score += 100
        if "reference" in n and "code" in n: score += 80
        if "code" in n: score += 25
        if arr.dtype.kind in "iu": score += 20
        if arr.ndim >= 2 and (arr.shape[-1] == 16 or arr.shape[0] == 16): score += 50
        return score

    def score_spk(item: tuple[str, Any, Any]) -> int:
        name, _, arr = item
        n = name.lower()
        score = 0
        if "ref_spk" in n: score += 100
        if "speaker" in n: score += 70
        if "spk" in n: score += 60
        if "embedding" in n: score += 40
        if "xvector" in n or "x_vector" in n: score += 50
        if arr.dtype.kind == "f": score += 20
        return score

    def score_tokens(item: tuple[str, Any, Any]) -> int:
        name, _, arr = item
        n = name.lower()
        score = 0
        if "ref_text" in n and "token" in n: score += 100
        if "text" in n and "id" in n: score += 50
        if "token" in n: score += 30
        if arr.dtype.kind in "iu": score += 20
        if arr.ndim == 1: score += 20
        return score

    code_candidates = sorted(arrays, key=score_code, reverse=True)
    spk_candidates = sorted(arrays, key=score_spk, reverse=True)
    tok_candidates = sorted(arrays, key=score_tokens, reverse=True)

    ref_code = code_candidates[0][2] if code_candidates and score_code(code_candidates[0]) >= 70 else None
    spk = spk_candidates[0][2] if spk_candidates and score_spk(spk_candidates[0]) >= 80 else None
    toks = tok_candidates[0][2] if tok_candidates and score_tokens(tok_candidates[0]) >= 80 else None

    trace["selected"] = {
        "referenceCodes": code_candidates[0][0] if ref_code is not None else None,
        "speakerEmbedding": spk_candidates[0][0] if spk is not None else None,
        "refTextTokens": tok_candidates[0][0] if toks is not None else None,
    }

    return ref_code, spk, toks, trace


def try_tokenize_ref_text(model: Any, ref_text: str):
    import numpy as np

    for attr in ["tokenizer", "processor"]:
        obj = getattr(model, attr, None)
        if obj is None:
            continue
        for call in ["encode", "__call__"]:
            fn = getattr(obj, call, None)
            if fn is None:
                continue
            try:
                result = fn(ref_text)
                named = flatten_named(result)
                for name, val in named:
                    arr = to_numpy(val)
                    if arr is not None and arr.dtype.kind in "iu" and arr.size > 0:
                        return np.asarray(arr).astype("int32").reshape(-1)
                arr = to_numpy(result)
                if arr is not None and arr.dtype.kind in "iu" and arr.size > 0:
                    return np.asarray(arr).astype("int32").reshape(-1)
            except Exception:
                continue
    return None


def write_i32(path: pathlib.Path, arr) -> dict[str, Any]:
    import numpy as np
    arr = np.asarray(arr).astype("int32")
    path.write_bytes(arr.astype("<i4", copy=False).tobytes(order="C"))
    return {"path": path.name, "dtype": "int32", "shape": list(arr.shape), "sha256": sha256_file(path)}


def write_f32(path: pathlib.Path, arr) -> dict[str, Any]:
    import numpy as np
    arr = np.asarray(arr).astype("float32")
    path.write_bytes(arr.astype("<f4", copy=False).tobytes(order="C"))
    return {"path": path.name, "dtype": "float32", "shape": list(arr.shape), "sha256": sha256_file(path)}


def update_variant_manifest(variant_path: pathlib.Path, manifest: dict[str, Any]) -> None:
    variant = json.loads(variant_path.read_text(encoding="utf-8"))
    variant["qwenArtifacts"] = {
        "status": "precomputed",
        "runtimeMode": manifest["runtimeMode"],
        "xVectorOnlyMode": manifest["xVectorOnlyMode"],
        "clonePromptManifestPath": "qwen_artifacts/clone_prompt_manifest.json",
        "referenceCodesPath": "qwen_artifacts/reference_codes.i32le",
        "referenceTextTokensPath": "qwen_artifacts/ref_text_tokens.i32le",
        "speakerEmbeddingPath": "qwen_artifacts/speaker_embedding.f32le",
        "officialTracePath": "qwen_artifacts/official_trace.json",
        "referenceRows": manifest["referenceCodes"]["shape"][0],
        "codebookCount": manifest["referenceCodes"]["codebookCount"],
        "speakerEmbeddingShape": manifest["speakerEmbedding"]["shape"],
        "refTextTokenCount": manifest["refTextTokens"]["shape"][0],
    }
    variant_path.write_text(
        json.dumps(variant, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def update_profile_metadata(profile_path: pathlib.Path) -> None:
    metadata_path = profile_path / "metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["allowRuntimeRefAudioEncoding"] = False
    metadata["runtimeCloneArtifacts"] = {
        "status": "precomputed",
        "description": "Reference audio/text were converted to reusable Qwen Base clone prompt artifacts by the Mac authoring precompute step.",
    }
    metadata_path.write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def audio_info(path: pathlib.Path) -> tuple[int | None, int | None, float | None]:
    try:
        import soundfile as sf
        info = sf.info(str(path))
        return info.samplerate, info.frames, float(info.duration)
    except Exception:
        return None, None, None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--variant", default="broadcast_reading_lazy")
    ap.add_argument("--official-qwen", default="ExternalReference/Qwen3-TTS-official")
    ap.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-Base")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--dtype", default="bfloat16")
    args = ap.parse_args()

    root = pathlib.Path(args.repo_root).expanduser().resolve()
    official = (root / args.official_qwen).resolve()
    if official.exists():
        sys.path.insert(0, str(official))

    profile = pathlib.Path(args.profile)
    if not profile.is_absolute():
        profile = (root / profile).resolve()
    variant_dir = profile / "variants" / args.variant
    ref_wav = variant_dir / "ref_audio" / "normalized" / "ref_24000_mono.wav"
    ref_text_path = variant_dir / "ref_text.txt"
    out_dir = variant_dir / "qwen_artifacts"
    out_dir.mkdir(parents=True, exist_ok=True)

    if not ref_wav.exists():
        raise SystemExit(f"missing ref wav: {ref_wav}")
    if not ref_text_path.exists():
        raise SystemExit(f"missing ref text: {ref_text_path}")
    ref_text = ref_text_path.read_text(encoding="utf-8").strip()
    if not ref_text:
        raise SystemExit("ref_text.txt is empty")

    from qwen_tts import Qwen3TTSModel  # official package/import

    kwargs: dict[str, Any] = {}
    # Keep this broad because the installed qwen-tts version may support either
    # local paths or hub ids and may or may not accept dtype/device_map on CPU.
    try:
        import torch
        if args.dtype.lower() in ("bf16", "bfloat16"):
            kwargs["dtype"] = torch.bfloat16
        elif args.dtype.lower() in ("fp16", "float16"):
            kwargs["dtype"] = torch.float16
        if args.device:
            kwargs["device_map"] = args.device
    except Exception:
        pass

    try:
        model = Qwen3TTSModel.from_pretrained(args.model, **kwargs)
    except TypeError:
        # Fallback for older official package signatures.
        model = Qwen3TTSModel.from_pretrained(args.model)

    prompt_items = model.create_voice_clone_prompt(
        ref_audio=str(ref_wav),
        ref_text=ref_text,
        x_vector_only_mode=False,
    )

    ref_code, speaker_embedding, ref_text_tokens, trace = choose_arrays(prompt_items)
    if ref_text_tokens is None:
        ref_text_tokens = try_tokenize_ref_text(model, ref_text)

    if ref_code is None:
        (out_dir / "official_trace.json").write_text(json.dumps(trace, indent=2), encoding="utf-8")
        raise SystemExit("could not locate reference codes in create_voice_clone_prompt output; see official_trace.json")
    if speaker_embedding is None:
        (out_dir / "official_trace.json").write_text(json.dumps(trace, indent=2), encoding="utf-8")
        raise SystemExit("could not locate speaker embedding in create_voice_clone_prompt output; see official_trace.json")
    if ref_text_tokens is None:
        (out_dir / "official_trace.json").write_text(json.dumps(trace, indent=2), encoding="utf-8")
        raise SystemExit("could not locate/tokenize ref text tokens; see official_trace.json")

    import numpy as np
    ref_code = np.asarray(ref_code)
    if ref_code.ndim == 3 and ref_code.shape[0] == 1:
        ref_code = ref_code[0]
    if ref_code.ndim == 2 and ref_code.shape[0] == 16 and ref_code.shape[1] != 16:
        ref_code = ref_code.T
    if ref_code.ndim != 2 or ref_code.shape[-1] != 16:
        raise SystemExit(f"reference code shape must normalize to [rows,16], got {ref_code.shape}")

    ref_text_tokens = np.asarray(ref_text_tokens).reshape(-1)
    speaker_embedding = np.asarray(speaker_embedding).reshape(-1)

    code_meta = write_i32(out_dir / "reference_codes.i32le", ref_code)
    spk_meta = write_f32(out_dir / "speaker_embedding.f32le", speaker_embedding)
    tok_meta = write_i32(out_dir / "ref_text_tokens.i32le", ref_text_tokens)

    sr, frames, dur = audio_info(ref_wav)
    manifest = {
        "schemaVersion": 1,
        "voiceID": "big_mike_base_clone_v1",
        "variantID": args.variant,
        "modelFamily": "qwen3-tts-base",
        "runtimeMode": "baseCloneICL",
        "xVectorOnlyMode": False,
        "language": "English",
        "sourceAudio": "../ref_audio/normalized/ref_24000_mono.wav",
        "sourceText": "../ref_text.txt",
        "referenceAudioSampleRate": sr,
        "referenceSampleCount": frames,
        "referenceDurationSeconds": dur,
        "refTextTokens": tok_meta,
        "referenceCodes": {**code_meta, "layout": "rows_x_codebooks", "codebookCount": 16},
        "speakerEmbedding": spk_meta,
        "officialQwen": {
            "repo": "QwenLM/Qwen3-TTS",
            "commit": repo_git_commit(official),
            "model": args.model,
            "functions": ["create_voice_clone_prompt", "generate_voice_clone", "speech_tokenizer.encode", "extract_speaker_embedding"],
        },
    }
    (out_dir / "clone_prompt_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    trace["manifest"] = manifest
    (out_dir / "official_trace.json").write_text(json.dumps(trace, indent=2, default=str), encoding="utf-8")
    update_variant_manifest(variant_dir / "variant.json", manifest)
    update_profile_metadata(profile)

    with (out_dir / "checksums.sha256").open("w", encoding="utf-8") as f:
        for name in ["clone_prompt_manifest.json", "reference_codes.i32le", "speaker_embedding.f32le", "ref_text_tokens.i32le", "official_trace.json"]:
            p = out_dir / name
            f.write(f"{sha256_file(p)}  {name}\n")

    print(json.dumps({
        "status": "ok",
        "out": str(out_dir),
        "referenceCodesShape": list(ref_code.shape),
        "speakerEmbeddingShape": list(speaker_embedding.shape),
        "refTextTokenCount": int(ref_text_tokens.shape[0]),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
