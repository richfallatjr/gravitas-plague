# Gravitas Plague — Turing System Architect Specification

Version: 0.1 draft for review  
Target: visionOS / Apple Vision Pro  
Primary goal: implement the Turing conversational voice system without vibe-coding the architecture into a dead end.

---

## 0. Purpose

The Turing System is the story-mode conversational voice pipeline for Gravitas Plague.

It is not a generic chatbot layer.

It is not a generic TTS wrapper.

It is a production system that connects authored episode scripts, Apple Foundation Models, Crunch-style chunking and segmentation, Qwen TTS through MLX, wall-snapped radio props, player dictation, and spatial playback.

The system must be built carefully from the beginning because it sits directly in the critical path for Story Mode, Prologue, Episode 1, and future character-driven episodes.

---

## 1. Source-of-truth design constraints

### 1.1 Text intelligence is Apple Foundation Models

All text-side intelligence uses Apple Foundation Models.

This includes:

- exact text speech segmentation
- intent-to-dialogue generation
- player conversation responses
- Bible selection
- Focus Bible chunk processing
- Focus result reduction
- final Focus-to-character speech
- JSON repair

Do not introduce another text model into this phase.

### 1.2 Voice generation is Qwen TTS through MLX

All runtime character speech is synthesized by Qwen TTS through MLX.

Target model:

```text
Qwen3-TTS-12Hz-1.7B-Base, 4-bit quantization
```

The implementation must run through MLX on the Apple GPU.

The implementation must not silently fall back to CPU-only inference.

The implementation must not ship Python.

The implementation must not ship PyTorch.

Qwen receives:

- final text
- emotional direction
- selected voice identity

Qwen does not receive episode control state, prop routing, device IDs, HUD state, or RealityKit data.

### 1.3 Foundation Models can run in parallel

Independent Foundation Models jobs may run in parallel through a bounded concurrency limiter.

This is required for long Bible Focus processing.

Parallelizable examples:

- per-chunk Focus summaries
- independent source chunk summaries
- independent exact segmentation jobs after sections are finalized
- independent JSON repairs when several chunks fail at once

Non-parallel examples:

- script node execution order
- trigger progression
- player dictation for the active turn
- final ordered playback
- Qwen TTS generation

### 1.4 Qwen TTS is sequential

Only one Qwen TTS generation job may run at a time in MVP.

No parallel Qwen synthesis.

No Qwen GPU batching in MVP.

Each spoken segment gets its own fresh synthesis session.

The shared immutable model weights may remain resident in memory, but request-local synthesis state must be released after each segment.

### 1.5 Qwen runs off MainActor

Qwen model loading, synthesis, cache work, and audio file writing must run off MainActor.

MainActor may only apply the final playback result to RealityKit / SwiftUI / audio emitters.

The Turing TTS scheduler must be an actor or equivalent concurrency boundary that is not `@MainActor`.

MainActor responsibilities:

- RealityKit entity mutations
- SwiftUI updates
- gaze interaction application
- existing HUD application
- attaching playback to spatial audio emitters
- starting/stopping playback on the final rendered audio

Off-main responsibilities:

- Foundation Models request construction
- Foundation Models calls
- JSON sanitation and gating
- Focus chunk processing
- Qwen synthesis
- MLX compute
- cache key resolution
- audio file persistence
- packet scheduling
- cancellation cleanup

### 1.6 Fresh Foundation Models sessions

Every Foundation Models query uses a fresh session.

Do not carry a long-running chat transcript.

Do not reuse a `LanguageModelSession` to preserve conversation.

Continuity must come from external state.

External state includes:

- active episode command
- active script trigger
- character writeup
- current player dictated input
- Bible catalog metadata
- Focus results from the current agentic loop

This applies to:

- voiceScript segmentation
- voicePrompt generation
- conversationPrompt response generation
- Focus chunk processing
- Focus reduction
- Focus-to-character speech
- JSON repair

### 1.7 Fresh Qwen synthesis sessions

Every spoken segment uses a fresh Qwen synthesis session.

The large model host may remain resident.

The segment session owns:

- segment text
- segment emotional prompt
- voice conditioning
- decoder state
- generated speech tokens
- temporary MLX arrays
- intermediate waveform buffers

When synthesis finishes:

1. 1copy or write the rendered audio into playback-safe storage
2. 2release the segment session
3. 3clear request-local MLX state where supported
4. 4return the rendered audio reference to the playback layer

No segment may depend on a previous segment’s decoder state.

### 1.8 No deterministic semantic fallback

Code may perform mechanical work.

Allowed:

- chunking by UTF-16 offsets
- stable indexing
- cache lookup
- packet scheduling
- file I/O
- playback scheduling
- structural JSON wrapper cleanup
- exact schema validation
- retry through Foundation Models

Forbidden:

- punctuation-based speech splitting
- sentence splitting as a fallback
- word-count splitting as a fallback
- character-count splitting as a fallback
- code-authored substitute dialogue
- code-authored summaries
- system TTS fallback
- prerecorded dialogue fallback
- changing the text to make a gate pass

If Foundation Models fails and repair fails, the operation fails.

### 1.9 No prerecorded dialogue

Character dialogue is generated at runtime.

A cloned voice profile may be stored in the repository.

A cloned voice profile is voice conditioning data, not spoken dialogue.

### 1.10 Existing subtitle HUD only shows player dictation

The existing subtitle HUD displays the player’s dictated words.

Qwen character speech is heard through spatial audio and is not subtitled.

Do not add a second transcript UI for Qwen responses in MVP.

This is intentional because gameplay recordings can show what the player said even when Apple’s capture does not include microphone audio.

### 1.11 Dynamic Profiles are not MVP

Do not build Apple Dynamic Profiles into MVP.

Do not build a complex prompt atom framework for MVP.

Use simple prompt templates stored as versioned resources.

The final prompt is assembled before each fresh Foundation Models request.

### 1.12 Memory Bible is deferred

Do not implement Memory Bible in this phase.

Do not implement automatic memory compaction in this phase.

Bible querying is required.

Memory Bible is a stretch goal.

---

## 2. Systems to reuse from Plague

The Turing System must integrate with existing Plague systems rather than rewriting them.

Required reuse targets:

- Room skinning flow
- Wall placement
- Wall occupancy
- Wall-mounted poster UI
- Existing HUD system
- Existing spatial audio infrastructure
- Character sidecars
- Jock animation runtime
- Existing Story/Horde mode separation
- Existing portal and prop placement patterns
- Existing MainActor RealityKit application layer

If Codex or the architect cannot find one of these systems by name, it must search the Plague repo and map the closest actual type names before implementing new systems.

---

## 3. Systems to reuse from Crunch

Do not import all of Crunch.

Only port the pipeline behaviors needed for Turing.

Required Crunch behaviors:

- exact segmentation for authored speech
- audiobook-style arbitrary-length text handling
- Focus-style chunk processing
- parallel Foundation Models chunk work
- sparse JSON return
- JSON sanitation
- JSON gate
- JSON repair through Foundation Models
- no deterministic semantic fallback
- packet-zero compute-ahead playback pattern
- cache identity rules

Key Crunch concepts to inspect:

```text
ResearchSummaryService.buildAggregate(...)
ResearchSummaryService.runChunkSummaries(...)
SummaryChunkConcurrencyLimiter
ChunkingUtilities.makeChunkJobs(...)
SummaryPromptBuilder.buildChunkPrompt(...)
SummaryPromptBuilder.buildFinalPrompt(...)
RadioCrunchPipeline
ResearchAssistantService.runFocus(...)
AudiobookPreparationService
TTSNarrationSegmentPlanner
AnchorBroadcastService
ResearchSummarySupport
```

Codex must locate the actual current file paths in the Crunch repo. The paths listed in conversation are examples from the developer machine and may not match the repository checkout.

---

## 4. Repository structure

Add a dedicated Turing module.

Suggested code layout:

```text
GravitasPlague/
  Turing/
    Core/
      TuringAction.swift
      TuringActionResult.swift
      TuringCoordinator.swift
      TuringRuntimeConfig.swift
      TuringMetrics.swift

    Models/
      TuringModelRegistry.swift
      TuringVoiceRegistry.swift
      TuringVoiceDescriptor.swift

    Foundation/
      FreshFoundationQueryRunner.swift
      FoundationParallelCoordinator.swift
      FoundationJSONSanitizer.swift
      FoundationJSONGate.swift
      FoundationRepairService.swift
      FoundationPromptTemplateStore.swift
      FoundationPromptRenderer.swift

    Chunking/
      ChunkJob.swift
      UTF16ChunkingUtilities.swift
      FocusChunkConcurrencyLimiter.swift
      FocusChunkAggregator.swift

    Speech/
      TuringSpeechSegment.swift
      TuringDialoguePlan.swift
      TuringPacketizer.swift
      TuringSpeechPipeline.swift

    Bible/
      TuringBibleCatalog.swift
      TuringBibleSource.swift
      TuringFocusSummaryService.swift
      TuringFocusPromptService.swift

    TTS/
      QwenTTSModelHost.swift
      QwenTTSSynthesisSession.swift
      QwenTTSSequentialScheduler.swift
      QwenTTSModelLoader.swift
      TuringAudioCache.swift
      TuringRenderedSegment.swift

    Interaction/
      TuringPropInteractionController.swift
      TuringGazeTargetComponent.swift
      TuringBillboardIconController.swift
      TuringDictationCoordinator.swift
      TuringHUDAdapter.swift

    Story/
      EpisodeScriptCompiler.swift
      EpisodeScriptCommand.swift
      EpisodeRuntimeNode.swift
      TuringScriptRuntime.swift
      TuringVoiceScriptStore.swift
      TuringCharacterProfile.swift

    Audio/
      TuringSpatialAudioAdapter.swift
      TuringRadioEffectProfile.swift

    Debug/
      TuringDebugView.swift
      TuringDebugHarness.swift
      TuringSoakTestRunner.swift
```

Suggested resource layout:

```text
Resources/
  Turing/
    Models/
      Qwen3TTS/
        Qwen3-TTS-12Hz-1.7B-Base-4bit/
      SpeechTokenizer/
        Qwen3-TTS-Tokenizer-12Hz/

    Voices/
      Library/
      Cloned/

    Prompts/
      voiceScript_exactSegmentation.txt
      voicePrompt_characterIntent.txt
      conversationPrompt_characterTurn.txt
      focusSummary_chunk.txt
      focusPrompt_characterSpeech.txt
      jsonRepair.txt

    Bibles/
      Episode01/
        catalog.json
        plague.txt
        big_mike.txt
        player_big_mike_relationship.txt

    Scripts/
      Prologue/
        prologue.json
        voiceScripts.json
      Episode01/

    Config/
      model-registry.json
      voice-registry.json
      turing-runtime.json
```

Large model assets should be Git LFS or equivalent.

Every model directory must include:

- model identifier
- revision
- quantization
- license
- tokenizer references
- checksum manifest

---

## 5. Runtime configuration

`turing-runtime.json` should include tunable values.

Example:

```json
{
  "schemaVersion": 1,
  "foundation": {
    "maxParallelRequests": 4,
    "maxChunkTokens": 2000,
    "aggregateBudgetTokens": 1250,
    "perChunkMetadataOverheadCharacters": 120
  },
  "tts": {
    "modelID": "qwen3-tts-12hz-1.7b-base-4bit",
    "synthesisMode": "sequential",
    "targetSegmentSecondsMin": 3.0,
    "targetSegmentSecondsMax": 5.0,
    "maxSegmentsBeforeSplit": 5,
    "requireGPU": true,
    "allowCPUFallback": false
  },
  "debug": {
    "enableMemoryMetrics": true,
    "soakTestIterations": 20
  }
}
```

---

## 6. Turing action model

The Turing coordinator exposes five action types.

```swift
enum TuringAction: Sendable {
    case voiceScript(VoiceScriptRequest)
    case voicePrompt(VoicePromptRequest)
    case conversationPrompt(ConversationPromptRequest)
    case focusSummary(FocusSummaryRequest)
    case focusPrompt(FocusPromptRequest)
}
```

These actions may include runtime routing fields, but runtime routing fields are never inserted into Foundation Models prompts unless the prompt explicitly needs them for the words.

For example, playback target belongs to playback.

It does not belong to the prompt.

---

## 7. Shared data contracts

### 7.1 Speech segment

```swift
struct TuringSpeechSegment: Codable, Sendable, Hashable {
    let text: String
    let emotion: String
}
```

A segment should target roughly three to five seconds of spoken audio.

The Foundation Model chooses the boundary.

Code validates; code does not split semantically.

### 7.2 Runtime playback target

This is runtime-only.

Do not send this to Foundation Models unless the line needs to mention the object.

```swift
enum TuringPlaybackTarget: Codable, Sendable, Hashable {
    case none
    case worldPosition(id: String)
    case prop(id: String)
    case character(id: String, anchor: String)
}
```

### 7.3 Voice identity

```swift
struct TuringVoiceDescriptor: Codable, Sendable, Hashable {
    let id: String
    let kind: Kind
    let resourcePath: String
    let revision: String?

    enum Kind: String, Codable, Sendable {
        case library
        case cloned
    }
}
```

### 7.4 Voice script definition

```swift
struct TuringVoiceScriptDefinition: Codable, Sendable, Hashable {
    let id: String
    let speaker: String
    let mode: Mode
    let text: String?
    let intent: String?
    let emotion: String
    let characterProfileID: String?
    let voiceID: String?

    enum Mode: String, Codable, Sendable {
        case exact
        case prompt
    }
}
```

### 7.5 Dialogue plan

```swift
struct TuringDialoguePlan: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let segments: [TuringSpeechSegment]
    let focus: TuringFocusRequest?
}
```

### 7.6 Focus request

```swift
struct TuringFocusRequest: Codable, Sendable, Hashable {
    let enabled: Bool
    let bibleID: String?
    let question: String?
    let bridgeSegments: [TuringSpeechSegment]
}
```

### 7.7 Focus summary result

```swift
struct TuringFocusSummaryResult: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let summary: String
    let supportingChunks: [TuringFocusProvenance]
}

struct TuringFocusProvenance: Codable, Sendable, Hashable {
    let chunkIndex: Int
    let absoluteStart: Int
    let absoluteEnd: Int
}
```

### 7.8 Chunk job

```swift
struct ChunkJob: Sendable, Codable, Hashable {
    let index: Int
    let offset: Int
    let end: Int
}
```

Offsets are absolute UTF-16 offsets into normalized source text.

### 7.9 Bible catalog entry

```swift
struct TuringBibleCatalogEntry: Codable, Sendable, Hashable {
    let id: String
    let type: String
    let scope: String
    let topics: [String]
}
```

Conversation prompts receive Bible catalog metadata only.

They do not receive Bible contents.

---

## 8. Prompt discipline

### 8.1 What belongs in prompts

`voiceScript` prompt receives:

- exact input text
- emotion
- segmentation rules
- return schema

`voicePrompt` prompt receives:

- input intent
- emotion
- character writeup
- rules
- return schema

`conversationPrompt` prompt receives:

- player dictation
- emotion
- character writeup
- Bible catalog metadata
- rules
- return schema

`focusSummary` prompt receives:

- selected Bible chunk
- focus question
- budget
- return schema

`focusPrompt` prompt receives:

- focus result
- emotion
- character writeup
- rules
- return schema

### 8.2 What does not belong in prompts

Do not include:

- device ID
- prop ID
- shelf ID
- gaze target state
- HUD state
- RealityKit entity IDs
- audio file names
- emitter locations
- playback routing
- button icon names
- checkpoint state
- unlock state

Those are runtime execution details.

They are not language-generation inputs.

---

## 9. Prompt templates

Prompts live as versioned resource files.

Do not bury them as scattered Swift string literals.

### 9.1 voiceScript exact segmentation prompt

Use the Crunch exact segmentation behavior.

This is for exact authored lines that must be preserved.

Template source should be based on Crunch `TTSNarrationSegmentPlanner` behavior.

System instructions:

```text
You are a narration segment planner for a text-to-speech pipeline.

Your job is to split narration text into natural spoken chunks that target the requested spoken duration while staying under the provided hard cap.

You must preserve the original text exactly. Do not paraphrase, summarize, rewrite, reorder, add words, remove words, or change punctuation. Only divide the text into spoken chunks.

Return JSON only.
Do not wrap the JSON in markdown.
Do not include commentary.
Do not include any extra keys outside the requested schema.

Important rules:
1. Preserve exact word order.
2. Preserve exact wording.
3. Prefer sentence boundaries.
4. If a sentence is too long, split at natural clause boundaries.
5. Avoid breaking names, titles, dates, abbreviations, acronyms, numbers, currency, quoted phrases, and parenthetical phrases unless absolutely necessary.
6. Avoid tiny orphan chunks.
7. Keep chunks near the target duration and avoid exceeding the hard cap.
8. The final chunk may be shorter.
9. Every character from the input text must appear exactly once across the output chunks, in the same order, ignoring only leading/trailing whitespace around each chunk.
10. If a perfectly natural split is impossible, choose the least awkward valid split.
```

User prompt:

```text
Split the following narration into spoken chunks targeting {targetSeconds} seconds each.
Hard cap per chunk: {maxSeconds} seconds.
Prefer chunks no shorter than 1.4 seconds unless it is the final chunk.

Output schema:
{
  "version": 1,
  "targetSeconds": {targetSeconds},
  "maxSeconds": {maxSeconds},
  "segments": [
    {
      "index": 0,
      "spokenText": "string"
    }
  ]
}

Narration text:
{text}
```

Turing converts this into `TuringSpeechSegment` by pairing each `spokenText` with the script emotion.

### 9.2 voicePrompt character intent prompt

This writes character speech from intent.

System instructions:

```text
You generate live character dialogue for Gravitas Plague.

Return JSON only.
Do not wrap JSON in markdown.
Do not include commentary.
Do not include extra keys.

Use the character writeup, input intent, and emotional tone to write final spoken dialogue.
Return natural spoken segments.
Each segment should be short enough for text-to-speech and should aim for three to five seconds.
Every segment must include an emotional performance description.
```

User prompt:

```text
Character:
{characterWriteup}

Intent:
{inputPrompt}

Emotional tone:
{emotion}

Return:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "spoken line",
      "emotion": "performance direction"
    }
  ]
}
```

### 9.3 conversationPrompt prompt

This handles real player dictation.

System instructions:

```text
You generate live in-character dialogue for Gravitas Plague.

Return JSON only.
Do not wrap JSON in markdown.
Do not include commentary.
Do not include extra keys.

Use the character writeup, player input, emotional tone, and Bible Catalog metadata.
The Bible Catalog lists available knowledge sources. It does not contain their knowledge.

If the current information is enough, return a direct response with focus.enabled false.
If deeper Bible knowledge is needed, return an immediate response plus focus.enabled true, one Bible ID, one direct focus question, and optional in-character bridge segments.

Every spoken segment must include text and an emotional performance description.
```

User prompt:

```text
Character:
{characterWriteup}

Player input:
{playerInput}

Emotional tone:
{emotion}

Bible Catalog:
{bibleCatalogJSON}

Return:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "spoken response",
      "emotion": "performance direction"
    }
  ],
  "focus": {
    "enabled": false,
    "bibleID": null,
    "question": null,
    "bridgeSegments": []
  }
}
```

### 9.4 focusSummary chunk prompt

This is adapted from Crunch Focus Mode.

It processes one deterministic source chunk using a focus question.

Template:

```text
Document title: {title}
Focus question: {question}
Label: "Summary chunk {chunkNumber} of {totalChunks} (absolute UTF-16 offsets {start}-{end})"
Budget: <= {perChunkBudgetCharacters} character output.
Target style: {targetStyle}

Task:
- Produce a high level summary of this chunk with the most interesting facts.
- Cleanse slurs, gratuitous violence, self-harm, and gore.
- Stay under the character budget.
- Avoid headline-length outputs or one-line restatements of the title.
- Fill most of the budget with concrete facts when supported.

Return STRICT JSON:
{
  "summary": "<dense narrative up to {perChunkBudgetCharacters} characters>"
}

Chunk text:
{chunk}
```

The result is not spoken directly.

### 9.5 focusPrompt final character speech prompt

This replaces Crunch’s old Focus final return for Plague.

The output is segmented emotional character speech.

System instructions:

```text
You convert focused Bible research into live character speech for Gravitas Plague.

Return JSON only.
Do not wrap JSON in markdown.
Do not include commentary.
Do not include extra keys.

Use the focus result, character writeup, and emotional tone to answer in character.
Return speech-ready segments.
Each segment should aim for three to five seconds.
Every segment must include text and an emotional performance description.
```

User prompt:

```text
Character:
{characterWriteup}

Focus result:
{focusResult}

Emotional tone:
{emotion}

Return:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "spoken character answer",
      "emotion": "performance direction"
    }
  ]
}
```

### 9.6 JSON repair prompt

```text
The prior response failed the required JSON schema.

Return corrected JSON only.
Do not use Markdown.
Do not add commentary.
Do not change the intended meaning.

Required schema:
{schemaExample}

Original input:
{originalInput}

Malformed response:
{malformedOutput}
```

---

## 10. JSON sanitation, gating, and repair

Allowed sanitation:

- trim whitespace
- remove one outer markdown code fence
- remove a byte-order mark
- extract one balanced top-level JSON object
- remove invalid non-printing control characters

Forbidden sanitation:

- inserting commas
- renaming keys
- changing quotes
- inventing missing fields
- deleting fields to force success
- rewriting text
- rewriting emotion
- creating fallback segments

Every action has a matching gate.

If gate fails:

1. 1create a fresh Foundation Models repair session
2. 2provide the original input and malformed output
3. 3request corrected JSON only
4. 4gate again
5. 5if it still fails, fail the operation

---

## 11. Chunking pipeline for Bible Focus

This is the Crunch Research Summary / Focus / Robot Radio chunking path.

It is not audio packetization.

### 11.1 Core idea

The app creates deterministic transport chunks.

Foundation Models does not decide the initial chunk boundaries.

Each chunk fits into the Foundation Models context window.

Each chunk is processed independently and in parallel.

The app sorts completed summaries back into source order.

The ordered aggregate feeds the final Focus step.

### 11.2 Chunk job model

```swift
struct ChunkJob: Sendable, Codable {
    let index: Int
    let offset: Int
    let end: Int
}
```

`offset` and `end` are absolute UTF-16 offsets into normalized source text.

### 11.3 Token estimate

Use the Crunch token estimate:

```swift
max(1, text.utf16.count / 4)
```

Constants:

```text
maxChunkTokens = 2000
aggregateBudgetTokens = 1250
maxThreadCount = 8
perChunkMetadataOverheadCharacters = 120
```

### 11.4 Chunk size calculation

Sequence:

1. 1Normalize text by replacing CRLF with LF and trimming outer whitespace.
2. 2Measure `totalLength = normalized.utf16.count`.
3. 3Estimate tokens with `max(1, normalized.utf16.count / 4)`.
4. 4Compute `targetChunkCount = ceil(estimatedTokens / maxChunkTokens)`.
5. 5Compute `chunkSizeUTF16 = ceil(totalLength / targetChunkCount)`.
6. 6Create chunk jobs.

Pseudo-code:

```swift
var jobs: [ChunkJob] = []
var offset = 0
var index = 0

while offset < totalLength {
    let end = min(totalLength, offset + chunkSizeUTF16)
    jobs.append(ChunkJob(index: index, offset: offset, end: end))
    offset = end
    index += 1
}
```

### 11.5 Parallel chunk processing

Each `ChunkJob` creates one fresh Foundation Models session.

Use a concurrency limiter similar to Crunch `SummaryChunkConcurrencyLimiter`.

The limiter caps cross-run Foundation Models concurrency.

Each result returns with its chunk index.

After all tasks complete, sort by index.

### 11.6 Final reduction

If the ordered aggregate fits within one final prompt, run one final Focus step.

If it does not fit:

1. 1split aggregate summaries into token-safe groups
2. 2process groups in parallel
3. 3reduce each group
4. 4repeat until the final aggregate fits
5. 5run final Focus step

For Plague, the final Focus step is `focusPrompt` and returns segmented emotional speech.

---

## 12. Audio segmentation and TTS pipeline

Audio segmentation is separate from Bible chunking.

Bible chunking handles long source research.

Audio segmentation handles speech performance.

### 12.1 Spoken segment target

Each speech segment should aim for three to five seconds.

For exact text, use the Crunch exact segmentation prompt.

For generated character speech, Foundation Models should return already segmented speech.

### 12.2 Sequential TTS

Each speech segment is rendered separately.

Process:

1. 1scheduler receives ordered speech segments
2. 2scheduler checks audio cache
3. 3cache miss creates fresh Qwen synthesis session
4. 4segment text, emotion, and voice profile enter Qwen
5. 5Qwen runs through MLX on the Apple GPU
6. 6audio is written to playback-safe storage
7. 7synthesis session is destroyed
8. 8scheduler proceeds to next segment

Only one synthesis may be active at a time.

### 12.3 GPU requirement

`QwenTTSModelHost` must verify MLX is configured for GPU-backed execution.

If the implementation cannot verify GPU execution directly, the debug UI must at minimum show the selected MLX device/backend and expose a failure state when GPU use is unavailable.

Do not silently run the production path on CPU.

### 12.4 Compute-ahead packets

Packets are scheduling groups.

They are not GPU batches.

If there are one to five segments, use one packet.

If there are more than five segments, split into two packets.

```swift
func packetize(_ segments: [TuringSpeechSegment]) -> [[TuringSpeechSegment]] {
    guard segments.count > 5 else { return [segments] }
    let split = Int(ceil(Double(segments.count) / 2.0))
    return [Array(segments[..<split]), Array(segments[split...])]
}
```

Render packet zero first.

Start playback when packet zero is ready.

Render packet one while packet zero plays.

Within each packet, render segments sequentially.

### 12.5 Cache key

Audio cache key must include:

- Qwen model ID
- Qwen model revision
- quantization
- speech tokenizer revision
- voice ID
- voice profile revision
- exact segment text
- exact emotional prompt
- language
- generation settings
- radio treatment profile if cached post-effect audio is stored

Do not reuse audio if any field differs.

---

## 13. TTS lifecycle soak test

This test is mandatory in Phase Zero.

Purpose: prove fresh synthesis sessions release memory.

Procedure:

1. 1Load Qwen model once.
2. 2Record warm post-load memory baseline.
3. 3Generate twenty unique short segments.
4. 4Each segment uses a fresh synthesis session.
5. 5Each output is persisted to playback-safe storage.
6. 6Each session releases request-local state.
7. 7Record memory after each cleanup.

Pass criteria:

- no sustained upward memory slope
- final memory stays near warm baseline within a configurable tolerance
- cancellation releases transient state
- failed synthesis releases transient state
- repeated playback does not require the synthesis session to remain alive

---

## 14. Device interaction and player dictation

### 14.1 Wall shelf placement

Initial Story Mode props should use wall-snapped shelves.

This avoids table detection.

Shelf bundles may include:

- walkie-talkie shelf
- crank radio shelf
- ham radio and generator bundle

Use existing room skinning, wall plane, and wall occupancy systems.

### 14.2 Gaze bounding box

Each interactive prop gets an invisible gaze bounding box.

Initial size can be approximately three times the visible prop volume, but must be tunable per asset.

When the player gazes inside the box, a circular billboard icon appears.

The icon always faces the player.

The player pinches the icon to interact.

This is contextual interaction, not knob simulation.

### 14.3 Dictation flow

When a conversational prop is activated:

1. 1Apple system dictation begins.
2. 2Partial player words display in the existing subtitle HUD.
3. 3The HUD displays only the player’s words.
4. 4When dictation ends, final text becomes input to `conversationPrompt`.
5. 5Qwen response is heard spatially.
6. 6Qwen response is not subtitled.

### 14.4 Playback routing

Playback routing happens after TTS.

Runtime systems decide which prop emits audio.

Do not include playback routing fields in Foundation Models prompts.

---

## 15. Episode authoring

Episode scripts are authored as ordered command arrays.

Each command is a compact single-key object.

The author does not write verbose typed runtime nodes.

The engine compiles the ordered list into typed runtime nodes.

### 15.1 Example authoring shape

```json
{
  "prologue": [
    { "music": "ambientHorrorLoop01.mp3" },
    { "dayNightUI": true },
    { "roomSkinFlow": true },
    {
      "wallPlace": [
        "posterUI",
        "door01",
        "window01",
        "crankRadioShelf",
        "walkieTalkieShelf",
        "hamRadioGeneratorBundle"
      ]
    },
    { "fadeOut": true },
    { "worldSpaceGraphic": { "title": "Prologue" } },
    { "fadeIn": true }
  ]
}
```

### 15.2 EpisodeScriptCompiler responsibilities

The compiler handles:

- auto IDs
- runtime node types
- blocking behavior
- validation
- trigger registration
- gaze interaction setup
- voice action routing
- Foundation Models calls
- Qwen TTS calls
- music changes
- checkpoint state
- unlock state

The authoring list remains the source of truth.

### 15.3 Required command types for Prologue MVP

```text
music
dayNightUI
roomSkinFlow
wallPlace
fadeOut
fadeIn
worldSpaceGraphic
triggerOn
triggerOff
hud
checkpoint
crankRadio
walkieTalkie
hamRadio
generator
door01
window01
playerDialogue
portalSpawn
unlockedUI
```

### 15.4 Action forms

Simple action:

```json
"action": "voiceScript01"
```

Nested action:

```json
"action": { "animation": "door01_open" }
```

Ordered action list:

```json
"action": [
  { "triggerOff": "walkieTalkie" },
  { "portalSpawn": "grandma_biped" },
  { "music": "combatMusicLoop01.mp3" },
  {
    "walkieTalkie": {
      "action": "voiceScript04"
    }
  }
]
```

### 15.5 Voice script table

Voice definitions live separately from the ordered script.

```json
{
  "voiceScripts": {
    "voicePrompt01": {
      "speaker": "player",
      "mode": "exact",
      "text": "I need to power this with the generator.",
      "emotion": "worried, practical"
    },
    "voiceScript01": {
      "speaker": "bigMike",
      "mode": "prompt",
      "intent": "Tell Rich that Gravitas is deploying antigen drones and he needs to send a beacon.",
      "emotion": "urgent but controlled"
    }
  }
}
```

Mode routing:

```text
mode exact -> voiceScript
mode prompt -> voicePrompt
player dictation -> conversationPrompt
focus requested -> focusSummary -> focusPrompt
```

---

## 16. Implementation phases

### Phase 0 — Model install, MLX host, debug harness

Deliverables:

- Qwen 1.7B 4-bit model downloaded into repo resource structure
- speech tokenizer downloaded into repo resource structure
- model registry
- voice registry
- Qwen MLX model host
- Qwen sequential scheduler
- debug UI
- GPU execution verification or explicit debug failure
- off-main synthesis execution
- TTS lifecycle soak test

Acceptance:

- generate one three-to-five-second line
- repeated generation works without reloading weights
- synthesis does not run on MainActor
- production path does not silently CPU fallback
- soak test passes

### Phase 1 — voiceScript

Deliverables:

- exact text request model
- Crunch exact segmentation prompt
- exact segmentation gate
- repair path
- sequential Qwen synthesis
- audio cache

Acceptance:

- authored exact text is preserved
- no words are added or removed
- Qwen speaks the exact segmented line
- no deterministic splitter is invoked

### Phase 2 — voicePrompt

Deliverables:

- intent-to-speech prompt
- character writeup support
- emotion support
- segmented emotional return
- Qwen playback

Acceptance:

- authored intent becomes character dialogue
- response returns speech segments with emotion
- character writeup affects wording
- prompt contains no runtime playback details

### Phase 3 — conversationPrompt

Deliverables:

- player dictation coordinator
- existing HUD integration for player words only
- conversation prompt
- Bible catalog metadata input
- focus true/false return
- bridge segment support

Acceptance:

- player speaks
- player words appear in existing HUD
- Foundation Models responds as character
- Qwen speaks response without subtitles
- focus request can be returned but does not have to complete yet

### Phase 4 — focusSummary and focusPrompt

Deliverables:

- deterministic UTF-16 chunking
- Focus chunk prompt
- bounded parallel Foundation Models chunk processing
- ordered aggregate
- final focusPrompt to segmented emotional speech
- sequential Qwen playback of deeper response

Acceptance:

- long Bible larger than context window is processed
- chunks run in parallel
- output order is restored
- final response is character speech, not a report
- Qwen remains sequential

### Phase 5 — EpisodeScriptCompiler

Deliverables:

- ordered command array parser
- command compiler
- runtime node executor
- triggerOn/triggerOff support
- voice action routing
- wall shelf integration
- gaze icon integration
- checkpoints and unlock UI routing

Acceptance:

- Prologue authoring list runs as data
- author does not write verbose typed nodes
- voice actions dispatch to correct Turing actions
- runtime routing stays out of prompts

### Phase 6 — Persistent voice cloning

Deliverables:

- macOS voice profile authoring utility
- clone profile format
- voice registry clone support
- runtime clone loading
- Big Mike test profile
- clone plus emotion feasibility test

Profile output structure:

```text
BigMike.plaguevoice/
  metadata.json
  speaker-embedding.bin
  reference-codes.bin
  reference-text-tokens.bin
```

Acceptance:

- no source recording required at runtime
- every line is still generated live
- Big Mike identity remains stable
- emotional prompts still affect delivery, or the wrapper feasibility issue is documented with next implementation step
- fresh TTS sessions continue to release memory

---

## 17. Codex reconnaissance tasks

Before implementation, Codex should inspect both repos.

### 17.1 Crunch repo tasks

Locate and summarize:

- AudiobookPreparationService
- TTSNarrationSegmentPlanner
- AnchorBroadcastService
- ResearchSummarySupport
- ResearchSummaryService.buildAggregate
- ResearchSummaryService.runChunkSummaries
- SummaryChunkConcurrencyLimiter
- ChunkingUtilities.makeChunkJobs
- SummaryPromptBuilder.buildChunkPrompt
- SummaryPromptBuilder.buildFinalPrompt
- RadioCrunchPipeline
- ResearchAssistantService.runFocus
- JSON gate and repair helpers
- packetizer and compute-ahead playback code
- render cache code

Codex should extract exact current code signatures and prompt bodies.

### 17.2 Plague repo tasks

Locate and summarize:

- RoomSkinningCoordinator
- WallPlaneManager
- WallPropOccupancyRegistry
- WallMountedPosterUIController
- existing subtitle HUD implementation
- spatial audio adapter/controller
- current mode menu / Story Mode / Horde Mode entry
- current prop placement code
- current gaze interaction or hand interaction code
- character sidecar loader
- Jock runtime
- existing MainActor hotspots

Codex should propose integration points without duplicating existing systems.

### 17.3 MLX/Qwen tasks

Codex should identify:

- available Swift Qwen3 TTS implementation status
- required model files
- tokenizer files
- how to force or verify MLX GPU execution
- how to create a fresh synthesis session while keeping weights resident
- how to clear transient MLX state
- whether 1.7B Base clone plus emotional prompt is currently supported
- whether a wrapper extension is required

---

## 18. Required tests

### 18.1 Unit tests

- exact segmentation gate
- dialogue plan gate
- focus result gate
- JSON sanitation
- JSON repair invocation
- chunk job coverage
- chunk ordering
- cache key identity
- packetization
- no deterministic fallback path

### 18.2 Parallel Foundation Models tests

- independent chunks run in parallel
- concurrency limit is respected
- fresh session per job
- results sort by source index
- cancellation cancels pending jobs
- one failed chunk reports its index

### 18.3 TTS tests

- synthesis runs off MainActor
- scheduler serializes jobs
- fresh session per segment
- cache hit avoids synthesis
- cache miss synthesizes once
- cancellation releases session state
- failed synthesis releases session state
- lifecycle soak test passes
- GPU execution is verified or debug-fails

### 18.4 Integration tests

- player dictation appears in existing HUD
- Qwen response has no subtitles
- audio emits from selected runtime prop after TTS
- wall shelf placement works
- script command compiles into runtime action
- voiceScript / voicePrompt / conversationPrompt route correctly
- focusSummary / focusPrompt agentic loop completes

---

## 19. Deferred work

Do not include in MVP:

- Dynamic Profiles
- Memory Bible
- automatic memory compaction
- Qwen subtitles
- high-fidelity knob manipulation
- multiple simultaneous Qwen TTS sessions
- TTS GPU batching
- system TTS fallback
- prerecorded dialogue fallback
- long-lived Foundation Models conversation sessions

---

## 20. Definition of done

The first Turing implementation is complete when:

- Qwen 1.7B 4-bit model is installed and loaded from the repo resource structure
- Qwen synthesis runs through MLX on the Apple GPU
- Qwen synthesis is off MainActor
- Qwen synthesis is sequential
- every segment uses a fresh synthesis session
- TTS lifecycle soak test passes
- Foundation Models handles text intelligence
- Foundation Models sessions are fresh per query
- Foundation Models chunk processing can run in parallel
- voiceScript works for exact authored text
- voicePrompt works for authored intent
- conversationPrompt works from player dictation
- player dictation appears in the existing HUD
- Qwen responses are spatial audio only and not subtitled
- focusSummary uses Crunch-style deterministic chunking and parallel processing
- focusPrompt turns Focus results into segmented emotional speech
- EpisodeScriptCompiler ingests the simple ordered authoring list
- runtime routing does not leak into prompts
- no deterministic semantic fallback exists
- no prerecorded dialogue fallback exists
