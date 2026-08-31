#!/usr/bin/env python3
"""Static anti-shortcut audit for the Angel camera-space projection runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=pathlib.Path, default=pathlib.Path.cwd())
    args = parser.parse_args()
    root = args.repository_root.resolve()
    resources = root / "Gravitas Plague/TuringResources/Turing/MindsEye/Projection"
    source = root / "Gravitas Plague/Gravitas Plague/Turing/MindsEye/Projection"
    profile_path = resources / "profiles/angel_head_v1.json"
    manifest_path = resources / "plates/angel_head_v1/source-manifest.json"
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    mask = profile["projectionReceiverUVMask"]
    mask_path = root / "Gravitas Plague/TuringResources" / mask["resourcePath"]

    require(profile["schemaVersion"] == 2, "profile is not schema v2")
    require(manifest["schemaVersion"] == 2, "plate manifest is not schema v2")
    require(manifest["compositeAlphaSemantics"] == "sourceOverOnly", "manifest alpha semantics changed")
    require("projectionMask" not in manifest, "plate manifest still owns receiver coverage")
    require(mask["convention"] == "darkProjectsLightSuppresses", "receiver inversion changed")
    require(mask["UVSetName"] == "primvars:st" and mask["UVSetIndex"] == 0, "receiver is not model UV0")
    require(mask_path.is_file() and sha256(mask_path) == mask["SHA256"], "receiver mask is missing or stale")
    require(not (resources / "masks/angel_head_v1_projection-mask-linear16.png").exists(), "camera-space runtime mask still ships")

    compositor = (source / "MindEyeProjectionCompositor.swift").read_text(encoding="utf-8")
    composite_shader = (source / "Shaders/MindEyeProjectionPlateComposite.metal").read_text(encoding="utf-8")
    material = (source / "MindEyeProjectionMaterialFactory.swift").read_text(encoding="utf-8")
    presenter = (
        root / "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03/LightTunnel/Chapter03LightTunnelPresenter.swift"
    ).read_text(encoding="utf-8")
    runtime_swift = "\n".join(path.read_text(encoding="utf-8") for path in (root / "Gravitas Plague/Gravitas Plague").rglob("*.swift"))

    require("projectionMask" not in compositor and "projectionMask" not in composite_shader,
            "camera-space compositor still binds receiver coverage")
    for token in ("projectedUV", "modelUVPrimvarsST", "projectionReceiverUVMask", "deformedObjectPosition", "clipFromEntity"):
        require(token in material, f"material omits coordinate contract token: {token}")
    require("projectionSampleUHorizontalFlip" in material,
            "camera-space photographic plate is not horizontally corrected at sampling")
    require("angel_posed_mouth_open_blend_01_v0001" not in runtime_swift,
            "runtime Swift loads or names the sculpt target")
    require("bundle.root.isEnabled = false" in presenter, "portal root is not hidden during preparation")
    require(presenter.index("bundle.root.isEnabled = false") < presenter.index("MindEyeAngelProjectionController.prepare"),
            "projection preparation begins before the root is hidden")
    require(presenter.index("MindEyeAngelProjectionController.prepare") < presenter.index("worldAnchor.addChild(bundle.root)"),
            "portal root attaches before projection/fallback decision")
    require(presenter.index("worldAnchor.addChild(bundle.root)") < presenter.index("bundle.root.isEnabled = true"),
            "portal root enables before it is attached")

    print(json.dumps({
        "status": "PASS",
        "profileSchema": profile["schemaVersion"],
        "manifestSchema": manifest["schemaVersion"],
        "receiverMaskSHA256": mask["SHA256"],
        "cameraSpaceRuntimeMaskPresent": False,
        "projectorCoordinate": "deformedObjectPosition->clipFromEntity->projectedUV",
        "projectionPlateUOrientation": "horizontallyCorrectedAtSample",
        "receiverCoordinate": "primvars:st/modelUV",
        "rootAtomicPresentation": True,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
