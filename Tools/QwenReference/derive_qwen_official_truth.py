#!/usr/bin/env python3
"""
Derive source-of-truth fixtures for Turing's native Qwen3-TTS VoiceDesign port.

This script is for Mac-side development only. It may import official qwen_tts,
PyTorch, transformers, and safetensors. None of those dependencies may ship in
the visionOS app.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib
import inspect
import json
import os
import pathlib
import subprocess
import sys
from dataclasses import asdict, dataclass
from typing import Any, Dict, Iterable, List, Optional

BIG_MIKE_INSTRUCT = (
    "A mid-forties Black American man with a large, grounded physical presence, "
    "like a retired college football lineman. Deep chest resonance, heavy but controlled breath, "
    "warm gravel, a Baltimore edge, streetwise but intelligent. Tough, protective, tired, "
    "and emotionally grounded. Former military, former athlete, current security guard. "
    "Not polished, not theatrical, not a radio announcer. He speaks like a real neighbor "
    "trying to keep his best friend alive. Thick, weighted vocal texture from age, size, "
    "and hard living; low, steady, and human."
)

HELLO_TEXT = "Hello world"


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


def tensor_summary(x: Any) -> Dict[str, Any]:
    try:
        import torch
        if isinstance(x, torch.Tensor):
            out = {
                "shape": list(x.shape),
                "dtype": str(x.dtype).replace("torch.", ""),
                "device": str(x.device),
                "numel": int(x.numel()),
            }
            if x.numel() <= 256:
                out["values"] = x.detach().cpu().tolist()
            return out
    except Exception:
        pass
    if hasattr(x, "shape"):
        return {"shape": list(x.shape), "dtype": str(getattr(x, "dtype", "unknown"))}
    return {"repr": repr(x)}


def load_safetensors_index(model_root: pathlib.Path) -> Dict[str, Any]:
    try:
        from safetensors import safe_open
    except Exception as e:
        raise SystemExit("Install safetensors in the reference venv: pip install safetensors") from e

    candidates = sorted(model_root.glob("*.safetensors"))
    if not candidates:
        raise SystemExit(f"No .safetensors files found in {model_root}")

    index: Dict[str, Any] = {"files": {}, "keys": {}}
    for st in candidates:
        file_info = {"sha256": sha256_file(st), "sizeBytes": st.stat().st_size, "keys": []}
        with safe_open(str(st), framework="pt", device="cpu") as f:
            for key in f.keys():
                tensor = f.get_tensor(key)
                rec = {
                    "file": st.name,
                    "shape": list(tensor.shape),
                    "dtype": str(tensor.dtype).replace("torch.", ""),
                }
                index["keys"][key] = rec
                file_info["keys"].append(key)
        index["files"][st.name] = file_info
    return index


def classify_weight_keys(keys: Iterable[str]) -> Dict[str, List[str]]:
    """Heuristic classifier for map generation only. Native code must use the generated exact map."""
    buckets = {
        "text_embeddings": [],
        "codec_embeddings": [],
        "text_projection": [],
        "talker_layers": [],
        "rms_norms": [],
        "attention_qkv_o": [],
        "mlp": [],
        "codec_head": [],
        "code_predictor": [],
        "code_predictor_embeddings": [],
        "code_predictor_heads": [],
        "small_to_mtp_projection": [],
        "speaker_encoder": [],
        "speech_tokenizer": [],
        "other": [],
    }
    for k in sorted(keys):
        lk = k.lower()
        if "speech_tokenizer" in lk or lk.startswith("speech_tokenizer"):
            buckets["speech_tokenizer"].append(k)
        elif "speaker_encoder" in lk:
            buckets["speaker_encoder"].append(k)
        elif "text" in lk and "embed" in lk:
            buckets["text_embeddings"].append(k)
        elif "codec_embedding" in lk or "embed_tokens" in lk or "input_embedding" in lk:
            buckets["codec_embeddings"].append(k)
        elif "text_projection" in lk:
            buckets["text_projection"].append(k)
        elif "code_predictor" in lk and ("lm_head" in lk or "head" in lk):
            buckets["code_predictor_heads"].append(k)
        elif "code_predictor" in lk and "embed" in lk:
            buckets["code_predictor_embeddings"].append(k)
        elif "code_predictor" in lk:
            buckets["code_predictor"].append(k)
        elif "small_to_mtp" in lk:
            buckets["small_to_mtp_projection"].append(k)
        elif any(s in lk for s in ["q_proj", "k_proj", "v_proj", "o_proj"]):
            buckets["attention_qkv_o"].append(k)
        elif any(s in lk for s in ["gate_proj", "up_proj", "down_proj"]):
            buckets["mlp"].append(k)
        elif "norm" in lk:
            buckets["rms_norms"].append(k)
        elif "codec_head" in lk or "lm_head" in lk:
            buckets["codec_head"].append(k)
        elif ".layers." in lk or ".blocks." in lk:
            buckets["talker_layers"].append(k)
        else:
            buckets["other"].append(k)
    return buckets


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--qwen-official", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--text", default=HELLO_TEXT)
    parser.add_argument("--instruct", default=BIG_MIKE_INSTRUCT)
    parser.add_argument("--language", default="English")
    parser.add_argument("--skip-forward", action="store_true", help="Only produce tokenizer/config/weight fixtures; do not run the model forward")
    args = parser.parse_args()

    repo_root = pathlib.Path(args.repo_root).resolve()
    qwen_official = (repo_root / args.qwen_official).resolve() if not pathlib.Path(args.qwen_official).is_absolute() else pathlib.Path(args.qwen_official).resolve()
    model_root = (repo_root / args.model).resolve() if not pathlib.Path(args.model).is_absolute() else pathlib.Path(args.model).resolve()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    sys.path.insert(0, str(qwen_official))

    # Required imports are intentionally delayed so missing env is reported clearly.
    try:
        import numpy as np
        import torch
        import soundfile as sf
        from qwen_tts import Qwen3TTSModel
    except Exception as e:
        raise SystemExit(
            "Failed to import official qwen_tts dependencies. Run in a reference venv with the official repo installed: "
            "python -m venv .venv-qwen-ref && source .venv-qwen-ref/bin/activate && "
            "pip install -e ExternalReference/Qwen3-TTS-official soundfile safetensors"
        ) from e

    commit = subprocess.check_output(["git", "-C", str(qwen_official), "rev-parse", "HEAD"], text=True).strip()
    required = [
        "qwen_tts/inference/qwen3_tts_model.py",
        "qwen_tts/inference/qwen3_tts_tokenizer.py",
        "qwen_tts/core/models/modeling_qwen3_tts.py",
        "qwen_tts/core/models/configuration_qwen3_tts.py",
        "qwen_tts/core/tokenizer_12hz/modeling_qwen3_tts_tokenizer_v2.py",
        "qwen_tts/core/tokenizer_12hz/configuration_qwen3_tts_tokenizer_v2.py",
        "examples/test_model_12hz_voice_design.py",
        "README.md",
        "pyproject.toml",
    ]
    source_hashes = {rel: sha256_file(qwen_official / rel) for rel in required if (qwen_official / rel).exists()}
    write_json(out / "qwen-reference-lock.json", {
        "schemaVersion": 1,
        "repoURL": "https://github.com/QwenLM/Qwen3-TTS.git",
        "resolvedCommit": commit,
        "referencePath": str(qwen_official),
        "sourceFileSHA256": source_hashes,
    })
    write_json(out / "source-file-hashes.json", source_hashes)

    assistant_text = f"<|im_start|>assistant\n{args.text}<|im_end|>\n<|im_start|>assistant\n"
    instruct_text = f"<|im_start|>user\n{args.instruct}<|im_end|>\n"
    write_json(out / "input.json", {"text": args.text, "instruct": args.instruct, "language": args.language})
    write_json(out / "prompt-strings.json", {"assistantText": assistant_text, "instructText": instruct_text})

    # Lightweight tokenizer/config without loading full weights first.
    try:
        from transformers import AutoProcessor
        processor = AutoProcessor.from_pretrained(str(model_root), local_files_only=True)
    except Exception as e:
        raise SystemExit(f"Failed to load AutoProcessor from {model_root}: {e}") from e

    assistant_ids = processor(text=assistant_text, return_tensors="pt", padding=True)["input_ids"]
    instruct_ids = processor(text=instruct_text, return_tensors="pt", padding=True)["input_ids"]
    tok = getattr(processor, "tokenizer", processor)
    special_ids = {}
    for name in ["bos_token_id", "eos_token_id", "pad_token_id", "unk_token_id"]:
        special_ids[name] = getattr(tok, name, None)
    write_json(out / "tokenizer-fixture.json", {
        "assistantText": assistant_text,
        "assistantInputIds": assistant_ids.cpu().tolist(),
        "assistantShape": list(assistant_ids.shape),
        "instructText": instruct_text,
        "instructInputIds": instruct_ids.cpu().tolist(),
        "instructShape": list(instruct_ids.shape),
        "specialIDs": special_ids,
    })

    # Config and safetensors truth.
    cfg = json.loads((model_root / "config.json").read_text())
    gen_cfg = json.loads((model_root / "generation_config.json").read_text()) if (model_root / "generation_config.json").exists() else {}
    tok_cfg = json.loads((model_root / "tokenizer_config.json").read_text()) if (model_root / "tokenizer_config.json").exists() else {}
    write_json(out / "config-fixture.json", {"config": cfg, "generationConfig": gen_cfg, "tokenizerConfig": tok_cfg})
    st_index = load_safetensors_index(model_root)
    write_json(out / "safetensors-index.json", st_index)
    write_json(out / "weight-name-map.json", classify_weight_keys(st_index["keys"].keys()))

    fixture_a_kwargs = {
        "do_sample": False,
        "top_k": 1,
        "top_p": 1.0,
        "temperature": 0.0,
        "repetition_penalty": 1.0,
        "subtalker_dosample": False,
        "subtalker_top_k": 1,
        "subtalker_top_p": 1.0,
        "subtalker_temperature": 0.0,
        "max_new_tokens": 8,
    }
    write_json(out / "generation-kwargs.json", {"fixtureA": fixture_a_kwargs, "productDefaultsSource": "official _merge_generate_kwargs + generation_config.json"})

    if args.skip_forward:
        print(f"Wrote tokenizer/config/weight fixtures to {out}")
        return

    # Full official model load. Prefer CPU for broad availability, but allow override.
    device = os.environ.get("QWEN_REF_DEVICE", "cpu")
    dtype_name = os.environ.get("QWEN_REF_DTYPE", "float32" if device == "cpu" else "bfloat16")
    dtype = getattr(torch, dtype_name)

    model = Qwen3TTSModel.from_pretrained(
        str(model_root),
        device_map=device,
        dtype=dtype,
        attn_implementation=os.environ.get("QWEN_REF_ATTN", "eager"),
        local_files_only=True,
    )

    # Recreate wrapper path explicitly for fixture extraction.
    input_ids = model._tokenize_texts([assistant_text])
    instruct_id_list = [model._tokenize_texts([instruct_text])[0]]
    gen_kwargs = model._merge_generate_kwargs(**fixture_a_kwargs)

    # Hook internal talker forward and optional code predictor calls. This keeps
    # official code as source of truth while recording graph boundary fixtures.
    stage: Dict[str, Any] = {
        "inputIds": [tensor_summary(x) for x in input_ids],
        "instructIds": [tensor_summary(x) for x in instruct_id_list],
        "generationKwargs": gen_kwargs,
        "talkerForwardCalls": [],
        "codePredictorCalls": [],
    }

    talker = model.model.talker
    # Qwen3-TTS passes custom generation kwargs such as trailing_text_hidden and
    # subtalker_* through Transformers' GenerationMixin into the talker forward.
    # On the pinned Transformers version, the generic validator rejects those
    # kwargs before the official forward can consume them. Disable only this
    # reference-time validator so the official Qwen graph remains the source of
    # truth for the generated fixtures.
    talker._validate_model_kwargs = lambda model_kwargs: None
    orig_talker_forward = talker.forward

    def recording_talker_forward(*f_args, **f_kwargs):
        call = {
            "args": [tensor_summary(x) for x in f_args],
            "kwargs": {k: tensor_summary(v) for k, v in f_kwargs.items() if k not in {"past_key_values", "cache_position"}},
            "hasPastKeyValues": f_kwargs.get("past_key_values") is not None,
        }
        out_obj = orig_talker_forward(*f_args, **f_kwargs)
        try:
            call["logits"] = tensor_summary(out_obj.logits)
            call["hiddenStatesLast"] = tensor_summary(out_obj.hidden_states[-1]) if getattr(out_obj, "hidden_states", None) else None
        except Exception as e:
            call["outputSummaryError"] = repr(e)
        if len(stage["talkerForwardCalls"]) < 4:
            stage["talkerForwardCalls"].append(call)
        return out_obj

    talker.forward = recording_talker_forward

    # Lower-level official generate route. This returns generated codec groups,
    # which are the real input to the speech tokenizer decoder.
    talker_codes_list, talker_hidden_states_list = model.model.generate(
        input_ids=input_ids,
        instruct_ids=instruct_id_list,
        languages=[args.language],
        non_streaming_mode=True,
        **gen_kwargs,
    )

    code_fixtures = []
    for i, codes in enumerate(talker_codes_list):
        summary = tensor_summary(codes)
        try:
            summary["firstRows"] = codes.detach().cpu()[: min(8, codes.shape[0])].tolist()
        except Exception:
            pass
        code_fixtures.append({"index": i, **summary})
    write_json(out / "codebook-fixture.json", {"talkerCodes": code_fixtures})

    hs_fixtures = []
    for i, hs in enumerate(talker_hidden_states_list):
        hs_fixtures.append({"index": i, **tensor_summary(hs)})
    write_json(out / "first-forward-fixture.json", {"stage": stage, "talkerHiddenStates": hs_fixtures})

    decode_inputs = [{"audio_codes": c} for c in talker_codes_list]
    write_json(out / "decode-input-fixture.json", {"items": code_fixtures})

    wavs, sr = model.model.speech_tokenizer.decode(decode_inputs)
    wav = np.asarray(wavs[0], dtype=np.float32)
    metrics = {
        "sampleRate": int(sr),
        "sampleCount": int(len(wav)),
        "finiteSampleCount": int(np.isfinite(wav).sum()),
        "peakAbs": float(np.max(np.abs(wav))) if len(wav) else 0.0,
        "rms": float(np.sqrt(np.mean(np.square(wav)))) if len(wav) else 0.0,
        "sha256Float32Raw": hashlib.sha256(wav.tobytes()).hexdigest(),
    }
    write_json(out / "stage-shapes.json", stage)
    # first-token fixture is derived from the first generated code row.
    first_token = None
    try:
        first_codes = talker_codes_list[0].detach().cpu()
        if first_codes.numel() > 0:
            first_token = first_codes[0].tolist()
    except Exception as e:
        first_token = {"error": repr(e)}
    write_json(out / "first-token-fixture.json", {"firstGeneratedCodeGroup": first_token})
    write_json(out / "reference-output-metrics.json", metrics)
    try:
        sf.write(str(out / "reference-output.wav"), wav, sr)
    except Exception as e:
        write_json(out / "reference-output-write-error.json", {"error": repr(e)})
    print(f"Wrote official Qwen truth fixtures to {out}")


if __name__ == "__main__":
    main()
