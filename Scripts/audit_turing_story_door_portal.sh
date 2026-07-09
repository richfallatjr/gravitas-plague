#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?repo root required}"

require_file() {
  test -f "$ROOT/$1" || {
    echo "Missing required file: $1" >&2
    exit 1
  }
}

require_rg() {
  local pattern="$1"
  local path="$2"
  rg -q "$pattern" "$ROOT/$path" || {
    echo "Missing pattern '$pattern' in $path" >&2
    exit 1
  }
}

require_file "Gravitas Plague/TuringResources/Turing/Props/turing_story_door_bundle_v1.usdz"
require_file "Gravitas Plague/TuringResources/Turing/Props/turing_story_door_bundle_v1.json"
require_file "Gravitas Plague/TuringResources/Turing/Audio/door/door-open-creak-01.wav"
require_file "Gravitas Plague/TuringResources/Turing/Audio/door/door-open-creak-02.wav"
require_file "Gravitas Plague/TuringResources/Turing/Audio/door/door-open-creak-03.wav"
require_file "Gravitas Plague/TuringResources/Turing/Audio/door/door-open-creak-04.wav"
require_file "Gravitas Plague/TuringResources/Turing/Audio/door/door-close-squeak-01.wav"
require_file "Gravitas Plague/TuringResources/Turing/Audio/door/door-close-contact-01.wav"

require_file "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorPortalContentProvider.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Interaction/TuringStoryDoorIconController.swift"

require_rg "storyDoorBundle" "Gravitas Plague/Gravitas Plague/RoomSkinning/WallPropOccupancyRegistry.swift"
require_rg "TuringStoryDoorHingePivot" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "TuringStoryDoorPanel_Root" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "TuringStoryDoorPortalPlane" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "floorSnapBasis: authored_origin" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "originClearanceMeters" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "TuringStoryDoorPortalSlab_Root" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "TuringStoryDoorPortalSlab_Root_PortalClone" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "portal slab pruned from passthrough render" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "passthroughPreserved: frame_and_panel" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "portal slab cloned into portal world" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
if rg -q "proceduralPortalPlaneIfMissing|procedural portal plane added|authored_portal_plane_missing_from_usdz" "$ROOT/Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"; then
  echo "Unexpected procedural door portal fallback still present" >&2
  exit 1
fi
require_rg "TuringStoryDoorIconAnchor" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "TuringStoryDoorAudioEmitter" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "PortalMaterial" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "PortalComponent" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift"
require_rg "day-groundplane-tile" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorPortalContentProvider.swift"
require_rg "night-groundplane-tile" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorPortalContentProvider.swift"
require_rg "yawOffsetRadians" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorPortalContentProvider.swift"
require_rg "6.0 \\* 0.0254" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorPortalContentProvider.swift"
require_rg "smoothstep|3 - 2|3.0 - 2.0" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_rg "hingeAxis: localZ" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_rg "145" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_rg "door-open-creak-01" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_rg "door-open-creak-04" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_rg "randomOpenSFX|randomElement" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_rg "door-close-squeak-01" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_rg "door-close-contact-01" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift"
require_rg "axisCorrection: x_plus_90_to_wall_normal" "Gravitas Plague/Gravitas Plague/Turing/Interaction/TuringStoryDoorIconController.swift"

if git -C "$ROOT" diff --name-only | rg 'Qwen|Prompt|voicePrompt|conversationPrompt|Audiobook|BaseClone|qwenclone'; then
  echo "Unexpected TTS/prompt/model files changed by door feature" >&2
  exit 1
fi

echo "Turing story door portal audit passed."
