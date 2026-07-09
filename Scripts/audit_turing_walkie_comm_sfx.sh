#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?repo root required}"

require_file() {
  local rel="$1"
  if [[ ! -f "$ROOT/$rel" ]]; then
    echo "Missing required file: $rel" >&2
    exit 1
  fi
}

require_rg() {
  local pattern="$1"
  local rel="$2"
  if ! rg -q "$pattern" "$ROOT/$rel"; then
    echo "Missing pattern '$pattern' in $rel" >&2
    exit 1
  fi
}

reject_rg() {
  local pattern="$1"
  local rel="$2"
  if rg -q "$pattern" "$ROOT/$rel"; then
    echo "Unexpected pattern '$pattern' in $rel" >&2
    exit 1
  fi
}

AUDIO_RES="Gravitas Plague/TuringResources/Turing/Audio/walkie"
AUDIO_SRC="Gravitas Plague/Gravitas Plague/Turing/Audio"
DIALOG_SRC="Gravitas Plague/Gravitas Plague/Turing/Dialog"
STORY_SRC="Gravitas Plague/Gravitas Plague/Turing/Story"

require_file "$AUDIO_RES/open-comm.wav"
require_file "$AUDIO_RES/send-comm.wav"
require_file "$AUDIO_RES/walkie-talkie-static-loop.mp3"
require_file "$AUDIO_RES/sending-static-loop.mp3"

for i in 01 02 03 04 05 06; do
  require_file "$AUDIO_RES/walkie-talkie-$i.wav"
done

require_file "$AUDIO_SRC/TuringWalkieCommsAssetStore.swift"
require_file "$AUDIO_SRC/TuringWalkieCommsFXController.swift"

require_rg "open-comm" "$AUDIO_SRC/TuringWalkieCommsAssetStore.swift"
require_rg "send-comm" "$AUDIO_SRC/TuringWalkieCommsAssetStore.swift"
require_rg "walkie-talkie-static-loop" "$AUDIO_SRC/TuringWalkieCommsAssetStore.swift"
require_rg "sending-static-loop" "$AUDIO_SRC/TuringWalkieCommsAssetStore.swift"
require_rg "walkie-talkie-%02d|walkie-talkie-01" "$AUDIO_SRC/TuringWalkieCommsAssetStore.swift"

require_rg "playOpenCommBeforeRecording" "$AUDIO_SRC/TuringWalkieCommsFXController.swift"
require_rg "playSendCommAndStartSendingLeadIn" "$AUDIO_SRC/TuringWalkieCommsFXController.swift"
require_rg "startSendingLeadIn" "$AUDIO_SRC/TuringWalkieCommsFXController.swift"
require_rg "stopSendingLeadIn" "$AUDIO_SRC/TuringWalkieCommsFXController.swift"
require_rg "Double.random\(in: 2\.0\.\.\.7\.0\)|2\.0\.\.\.7\.0" "$AUDIO_SRC/TuringWalkieCommsFXController.swift"
require_rg "random pre-playback burst started" "$AUDIO_SRC/TuringWalkieCommsFXController.swift"

require_rg "commSFX" "$AUDIO_SRC/TuringWalkieOneShotClipPlayer.swift"
require_rg "TuringWalkieAudio_CommSFXLane" "$AUDIO_SRC/TuringWalkieOneShotClipPlayer.swift"

require_rg "startSendingStaticLoop" "$AUDIO_SRC/TuringWalkieStaticLoopController.swift"
require_rg "stopSendingStaticLoop" "$AUDIO_SRC/TuringWalkieStaticLoopController.swift"
require_rg "startAmbientWalkieStaticLoop" "$AUDIO_SRC/TuringWalkieStaticLoopController.swift"
require_rg "TuringWalkieAudio_SendingStaticLane" "$AUDIO_SRC/TuringWalkieStaticLoopController.swift"

require_rg "walkie-talkie-static-loop|ambient walkie static" "$AUDIO_SRC/TuringRadioStaticLeadInController.swift"

# Dictation integration can be in Dialog or Story depending on current repo layout.
if ! rg -q "playOpenCommBeforeRecording" "$ROOT/$DIALOG_SRC" "$ROOT/$STORY_SRC" "$ROOT/$AUDIO_SRC"; then
  echo "Missing integration call: playOpenCommBeforeRecording" >&2
  exit 1
fi
if ! rg -q "playSendCommAndStartSendingLeadIn" "$ROOT/$DIALOG_SRC" "$ROOT/$STORY_SRC" "$ROOT/$AUDIO_SRC"; then
  echo "Missing integration call: playSendCommAndStartSendingLeadIn" >&2
  exit 1
fi

require_rg "stopSendingLeadIn" "$AUDIO_SRC/TuringStoryWalkiePlaybackCoordinator.swift"
require_rg "firstPlaybackStarting" "$AUDIO_SRC/TuringStoryWalkiePlaybackCoordinator.swift"

# Playback code must not stomp recording with playback category.
if rg -n "setCategory\(\.playback" "$ROOT/$AUDIO_SRC"; then
  echo "FAIL: Turing audio code still sets AVAudioSession category to .playback" >&2
  exit 1
fi

# This integration must not touch Qwen source files.
if git -C "$ROOT" diff --name-only | rg "Turing/QwenNative|TuringQwenNativeBaseClone|TuringQwenNativeGenerationScheduler"; then
  echo "FAIL: walkie comm SFX patch should not modify Qwen native runtime files" >&2
  exit 1
fi

echo "Turing walkie comm SFX audit passed."
