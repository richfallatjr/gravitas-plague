#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?repo root required}"
APP="$ROOT/Gravitas Plague/Gravitas Plague"
RES="$ROOT/Gravitas Plague/TuringResources/Turing"

fail() { echo "[FAIL] $*" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
require_rg() { local p="$1" f="$2"; rg -q "$p" "$f" || fail "missing pattern '$p' in $f"; }
reject_rg() { local p="$1" f="$2"; if rg -q "$p" "$f"; then fail "unexpected pattern '$p' in $f"; fi }

require_file "$RES/Audio/prerecordings/pr-big-mike-rich-contact.mp3"
require_file "$RES/Prerecordings/prologue.walkie.bigMike.richContact.001.json"
require_file "$APP/Turing/Dialog/TuringConversationSeed.swift"
require_file "$APP/Turing/Dialog/TuringPrerecordingDescriptor.swift"
require_file "$APP/Turing/Dialog/TuringPrerecordingSeededPromptRunner.swift"

require_rg 'pr-big-mike-rich-contact.mp3' "$RES/Prerecordings/prologue.walkie.bigMike.richContact.001.json"
require_rg 'Hey Rich you there' "$RES/Prerecordings/prologue.walkie.bigMike.richContact.001.json"
require_rg 'You are asking if Rich can hear you' "$RES/Prerecordings/prologue.walkie.bigMike.richContact.001.json"

require_rg 'struct TuringConversationSeed' "$APP/Turing/Dialog/TuringConversationSeed.swift"
require_rg 'TuringConversationPromptContext' "$APP/Turing/Dialog/TuringConversationSeed.swift"
require_rg 'updatePrerecording' "$APP/Turing/Dialog/TuringConversationSeed.swift"
require_rg 'context\(for key' "$APP/Turing/Dialog/TuringConversationSeed.swift"

require_rg 'prerecordingTranscript' "$APP/Turing/Dialog/TuringDialoguePayloads.swift"
require_rg 'voicePromptSeedIntent' "$APP/Turing/Dialog/TuringDialoguePayloads.swift"
require_rg 'lastVoicePromptSeed' "$APP/Turing/Dialog/TuringDialoguePayloads.swift"
require_rg 'conversationSeed' "$APP/Turing/Dialog/TuringDialoguePayloads.swift"

require_rg 'Prerecording transcript' "$RES/Prompts/voicePrompt_characterIntent.txt"
require_rg 'conversationSeed' "$RES/Prompts/voicePrompt_characterIntent.txt"
require_rg 'Latest voicePrompt seed' "$RES/Prompts/conversationPrompt_playerTurn_noBible.txt"
require_rg 'prerecordingTranscript' "$RES/Prompts/conversationPrompt_playerTurn_noBible.txt"
require_rg 'lastVoicePromptSeed' "$RES/Prompts/conversationPrompt_playerTurn_noBible.txt"

reject_rg 'Bible' "$RES/Prompts/conversationPrompt_playerTurn_noBible.txt"
reject_rg 'Focus' "$RES/Prompts/conversationPrompt_playerTurn_noBible.txt"

require_rg 'case prerecording' "$APP/Turing/Audio/TuringWalkieOneShotClipPlayer.swift"
require_rg 'TuringWalkieAudio_PrerecordingLane' "$APP/Turing/Audio/TuringWalkieOneShotClipPlayer.swift"
require_rg 'enqueuePrerecording' "$APP/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
require_rg 'prerecording playback started' "$APP/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
require_rg 'runVoicePromptAfterPrerecording' "$APP/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift"
require_rg 'runBigMikeRichContact' "$APP/Turing/Dialog/TuringPrerecordingSeededPromptRunner.swift"
require_rg 'Run Big Mike Rich Contact PR Seed' "$APP/Turing/Story/TuringEpisodePickerView.swift"

require_rg 'makeFresh2Pool' "$APP/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift"
require_rg 'makeFresh2Scheduler' "$APP/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift"

if rg -q 'focus|Focus|Bible|bible' "$APP/Turing/Dialog/TuringPrerecordingSeededPromptRunner.swift"; then
  fail "prerecording seeded runner must not reference Bible/Focus"
fi

echo "[PASS] Turing Rich Contact prerecording seeded prompt audit passed."
