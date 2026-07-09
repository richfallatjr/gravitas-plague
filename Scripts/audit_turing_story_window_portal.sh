#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?repo root required}"

require_file() {
  test -f "$ROOT/$1" || {
    echo "Missing required file: $1" >&2
    exit 1
  }
}

require_missing_file() {
  test ! -f "$ROOT/$1" || {
    echo "Unexpected stale file: $1" >&2
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

reject_rg() {
  local pattern="$1"
  local path="$2"
  if rg -q "$pattern" "$ROOT/$path"; then
    echo "Unexpected pattern '$pattern' in $path" >&2
    exit 1
  fi
}

require_file "Gravitas Plague/TuringResources/Turing/Props/turing_story_window_bundle_v1.usdz"
require_file "Gravitas Plague/TuringResources/Turing/Props/turing_story_wall_bundle_v1.usdz"
require_missing_file "Gravitas Plague/TuringResources/Turing/Props/ao.png"
unzip -l "$ROOT/Gravitas Plague/TuringResources/Turing/Props/turing_story_window_bundle_v1.usdz" | rg -q "textures/ao\\.png" || {
  echo "Missing embedded textures/ao.png in turing_story_window_bundle_v1.usdz" >&2
  exit 1
}
unzip -l "$ROOT/Gravitas Plague/TuringResources/Turing/Props/turing_story_wall_bundle_v1.usdz" | rg -q "textures/ao\\.png" || {
  echo "Missing embedded textures/ao.png in turing_story_wall_bundle_v1.usdz" >&2
  exit 1
}
require_file "day-groundplane-tile.png"
require_file "night-groundplane-tile.png"

require_file "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundlePlacement.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowPortalContentProvider.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowGlassMaterialFactory.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Interaction/TuringStoryPosterDayNightIconController.swift"

require_rg "storyWindowBundle" "Gravitas Plague/Gravitas Plague/RoomSkinning/WallPropOccupancyRegistry.swift"
require_rg "wallPoster" "Gravitas Plague/Gravitas Plague/RoomSkinning/WallPropOccupancyRegistry.swift"
require_rg "hordePortal" "Gravitas Plague/Gravitas Plague/RoomSkinning/WallPropOccupancyRegistry.swift"
require_rg "storyWalkieBundle" "Gravitas Plague/Gravitas Plague/RoomSkinning/WallPropOccupancyRegistry.swift"

require_rg "TuringStoryWindowFrame_Root" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "TuringStoryWindowGlass" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "TuringStoryWindowPortalPlane" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "TuringStoryWindowDayNightIconAnchor" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "scanned_floor_visual_bottom_2_8ft_no_wall_y_clamp" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "floor-relative placement proof" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "groundedRootLocalY" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "preferredBottomHeightMeters" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
reject_rg "clampedY" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "PortalComponent" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "PortalMaterial" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "WorldComponent" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "occlusion01" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "ao" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "textures/ao.png" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "embedded_usdz_texture" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "expectedEmbedded: textures/ao.png" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "PortalGlyphMaskTextureCache" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "UIColor.black" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "occlusion mask material applied" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
require_rg "usdzAuthoredMaterialOverridden: true" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
reject_rg "sidecarNames" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"
reject_rg "expectedSidecar" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift"

require_rg "textures/ao.png" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
require_rg "embedded_usdz_texture" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
require_rg "expectedEmbedded: textures/ao.png" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
require_rg "PortalGlyphMaskTextureCache" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
require_rg "UIColor.black" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
require_rg "occlusion mask material applied" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
require_rg "usdzAuthoredMaterialOverridden: true" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
reject_rg "sidecarNames" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"
reject_rg "expectedSidecar" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift"

require_rg "PortalHDRIAtmosphere" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowPortalContentProvider.swift"
require_rg "HordePortalGroundDiscFactory" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowPortalContentProvider.swift"
require_rg "day-groundplane-tile" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowPortalContentProvider.swift"
require_rg "night-groundplane-tile" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowPortalContentProvider.swift"
require_rg "groundDiscFloorOffsetMeters" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowPortalContentProvider.swift"
require_rg "2.5 \\* 0.3048" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowPortalContentProvider.swift"
require_rg "day-groundplane-tile" "Gravitas Plague/Gravitas Plague.xcodeproj/project.pbxproj"
require_rg "night-groundplane-tile" "Gravitas Plague/Gravitas Plague.xcodeproj/project.pbxproj"
require_rg "forest-overcast-01" "Gravitas Plague/Gravitas Plague/RoomSkinning/RoomSkinningModels.swift"
require_rg "forest-night-01" "Gravitas Plague/Gravitas Plague/RoomSkinning/RoomSkinningModels.swift"

require_rg "PhysicallyBasedMaterial" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowGlassMaterialFactory.swift"
require_rg "0.65" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowGlassMaterialFactory.swift"
require_rg "0.90" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowGlassMaterialFactory.swift"
require_rg "clearcoat" "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowGlassMaterialFactory.swift"

require_rg "TuringStoryDayNightPosterButtonComponent" "Gravitas Plague/Gravitas Plague"
require_rg "WallPosterDayNight_TuringWindow" "Gravitas Plague/Gravitas Plague"
require_rg "WallStickerStyle.twoStopsDownTint" "Gravitas Plague/Gravitas Plague/Turing/Interaction/TuringStoryPosterDayNightIconController.swift"
require_rg "return \"sun\"" "Gravitas Plague/Gravitas Plague/Turing/Interaction/TuringStoryPosterDayNightIconController.swift"
require_rg "return \"moon\"" "Gravitas Plague/Gravitas Plague/Turing/Interaction/TuringStoryPosterDayNightIconController.swift"
require_rg "updateTuringWindowDayNightIcon" "Gravitas Plague/Gravitas Plague"
require_rg "togglePortalHDRIAtmosphere" "Gravitas Plague/Gravitas Plague"

require_rg "TuringStoryWindowBundleController" "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
require_rg "updateAtmosphereIfNeeded" "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"

if rg -n "Qwen|TuringGapAudio|TuringPlayback|BigMike|voicePrompt|dictation" "$ROOT/Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindow"*; then
  echo "FAIL: window portal files should not reference Qwen/playback/dictation systems" >&2
  exit 1
fi

echo "Turing Story window portal audit passed."
