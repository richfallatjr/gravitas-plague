#!/usr/bin/env python3
"""
Mac-only helper for rendering the Big Mike broadcast with the official Qwen
reference implementation.

This file is intentionally outside the app runtime. The visionOS app must not
depend on Python, PyTorch, remote model downloads, or prerecorded production
dialogue. Use this script only to create a show-off/reference WAV and metadata
while the native Swift/MLX dynamic path is being completed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys


BIG_MIKE_TEXT = """Rich, listen to this shit.

THE GRAVITAS PLAGUE SPREADS

Officials are warning residents to stay indoors after new cases of the Gravitas Plague were confirmed across the city.

Doctors say the illness attacks the brain's fear response. Early victims may seem confused, sleepless, or strangely calm. Later symptoms include cloudy eyes, broken speech, fixation on movement, and sudden violence.

One hospital worker said, "They look awake, but unreachable."

The infected are not dead. They are living hosts with severe brain damage.

Residents are advised to lock doors, avoid contact with aggressive animals, and report any bite or fluid exposure immediately.

If someone you know appears infected, do not open the door.

If the eyes cloud, isolate.

If speech fails, do not negotiate."""


BIG_MIKE_INSTRUCT = """Voice ID: BIG_MIKE_VD_V1.

Male, mid-forties, Black American. Large grounded presence like a retired college football lineman. Low male pitch 2/7. Vocal weight 6/7. Chest resonance 6/7. Brightness 2/7. Warmth 5/7. Warm gravel 5/7. Slight lived-in rasp 3/7. Breath 4/7: heavy but controlled. Nasality 1/7. Articulation 5/7: clear but casual. Pace 3/7: measured, unhurried, a little lazy. Regional edge 3/7: subtle Baltimore. Energy 3/7: restrained, unimpressed, protective underneath. Streetwise, intelligent, tired, emotionally grounded. Former military, former athlete, security guard. Real neighbor voice, not polished, theatrical, announcer-like, villainous, or cartoonish. Keep this identity.

Performance:
Reading to Rich like, "Rich, listen to this shit." Tired, lazy, unimpressed, a little disgusted by official wording. Protective underneath, not panicked. Low volume, dry delivery, heavy breath, restrained intensity, no shouting. Keep BIG_MIKE_VD_V1 stable; change delivery only."""


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--qwen-official", default="ExternalReference/Qwen3-TTS-official")
    parser.add_argument(
        "--model",
        default="Gravitas Plague/Gravitas Plague/TuringResources/Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16",
    )
    parser.add_argument("--out", default="Tools/TuringQwenOfflineRender/Output/big_mike_broadcast_reference")
    args = parser.parse_args()

    repo_root = pathlib.Path(args.repo_root).resolve()
    official = (repo_root / args.qwen_official).resolve()
    model = (repo_root / args.model).resolve()
    out = (repo_root / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    derive = pathlib.Path("/Users/richardfallat/Downloads/derive_qwen_official_truth.py")
    if not derive.exists():
        print(f"Missing derive script: {derive}", file=sys.stderr)
        return 2

    cmd = [
        sys.executable,
        str(derive),
        "--repo-root",
        str(repo_root),
        "--qwen-official",
        str(official),
        "--model",
        str(model),
        "--out",
        str(out),
        "--text",
        BIG_MIKE_TEXT,
        "--instruct",
        BIG_MIKE_INSTRUCT,
        "--language",
        "English",
    ]
    subprocess.check_call(cmd)

    wav = out / "reference-output.wav"
    metadata = {
        "schemaVersion": 1,
        "purpose": "offline_big_mike_broadcast_reference",
        "runtimeUseAllowed": False,
        "text": BIG_MIKE_TEXT,
        "instruction": BIG_MIKE_INSTRUCT,
        "modelPath": str(model),
        "officialQwenPath": str(official),
        "referenceWav": str(wav),
        "referenceWavSHA256": sha256_file(wav) if wav.exists() else None,
    }
    (out / "big_mike_broadcast_reference_metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote offline Big Mike reference under {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
