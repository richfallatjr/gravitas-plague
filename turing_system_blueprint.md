# Gravitas Plague Turing System Blueprint

Version: 0.1 implementation blueprint

Source spec: `turing_system_spec.md`

Target app: Gravitas Plague on visionOS / Apple Vision Pro

Primary reuse source: Gravitas Crunch text, chunking, JSON, and sequential speech pipeline patterns

Primary Plague integration shell: `PlagueImmersiveCoordinator`

## 1. Non-negotiable rules

The Turing system is a story-mode voice runtime, not a chatbot wrapper and not a generic TTS layer.

These rules control every implementation choice:

1. Apple Foundation Models are the only text intelligence layer.
2. Qwen TTS through MLX is the only runtime character voice generation layer.
3. Qwen must run on Apple GPU. No silent CPU fallback.
4. Do not ship Python or PyTorch.
5. Use a fresh Foundation Models session for every prompt.
6. Use a fresh Qwen synthesis session for every spoken segment.
7. Qwen TTS is sequential in MVP. One segment render at a time.
8. Foundation Models chunk work may run in bounded parallel.
9. MainActor only applies RealityKit, SwiftUI, interaction, and playback state.
10. Code may do mechanical transport work only.
11. No deterministic semantic fallback. If Foundation Models fails and Foundation Models repair fails, fail the operation.
12. Qwen character speech is spatial audio, not subtitle HUD text.
13. Existing subtitle HUD remains for player dictation only.
14. No prerecorded character dialogue in MVP.

Allowed mechanical work:

- UTF-16 chunking by offsets
- stable indexing
- cache lookup
- ordered segment scheduling
- file IO
- playback scheduling
- structural JSON wrapper cleanup
- strict schema validation
- retry through Foundation Models

Forbidden fallback work:

- punctuation splitting
- sentence splitting
- word-count splitting
- character-count speech splitting
- code-authored substitute dialogue
- code-authored summaries
- system TTS fallback
- prerecorded dialogue fallback
- mutating generated words or emotions to satisfy a gate
- tolerant semantic salvage from malformed JSON

## 2. What to port from Crunch

Do not import all of Crunch. Port the behavior and contracts that make the pipeline reliable.

Useful Crunch reference files:

```text
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/AI/ChunkingUtilities.swift
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/AI/ResearchSummaryService.swift
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/AI/ResearchSummarySupport.swift
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/AI/TTSNarrationSegmentPlanner.swift
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/AI/AudiobookPreparationService.swift
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/Audiobook/ArticleAudiobookPreparationCoordinator.swift
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/AI/AnchorBroadcastService.swift
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/AI/RadioSummaryFinalizerService.swift
Gravitas Crunch/Gravitas Crunch/GravitasCrunch/Services/Radio/RadioCrunchPipeline.swift
```

Port these patterns:

- `ChunkJob(index, offset, end)` using UTF-16 offsets.
- `ChunkingUtilities.substring` and `makeChunkJobs`.
- `TokenEstimator.estimateTokens`: `max(1, text.utf16.count / 4)`.
- `SummaryChunkConcurrencyLimiter` actor shape.
- `ResearchSummaryService.buildAggregate` chunk count math.
- `ResearchSummaryService.runChunkSummaries` bounded parallel task-group structure.
- `SummaryPromptBuilder.buildChunkPrompt` sparse JSON chunk prompt pattern.
- `TTSNarrationSegmentPlanner` exact text segmentation prompt pattern.
- `AudiobookPreparationService` JSON repair loop shape.
- `ArticleAudiobookPreparationCoordinator` compute-ahead idea, adapted to first-segment playback and sequential segment rendering.
- Cache identity discipline: model revision, voice revision, text, emotion, tokenizer, quantization, language, and generation settings must affect the key.

Do not port these Crunch behaviors:

- PocketTTS model integration.
- PocketTTS dB tuning.
- PocketTTS execution gates.
- Deterministic semantic segmentation fallbacks.
- Tolerant JSON semantic salvage that extracts a field and pretends the payload is valid.
- Radio music bed and ducking unless a Story radio prop explicitly asks for it.
- Any text mutation that exists only to satisfy PocketTTS constraints.

Important delta from Crunch:

Crunch currently has some older fallback paths in `TTSNarrationSegmentPlanner`, `AudiobookPreparationService`, `SummaryChunkDecoder`, and radio finalization helpers. Turing must not inherit those. Turing keeps wrapper cleanup and strict decode, then uses a fresh Foundation Models repair session. If repair still fails, Turing fails the operation.

## 3. What to reuse from Plague

Turing should not rebuild room, prop, audio, or HUD systems. It should attach to existing Plague infrastructure.

Current Plague integration map:

```text
PlagueImmersiveCoordinator
  MainActor shell for RealityKit application and existing runtime ownership.

PhaseOneSpatialProvider
  ARKit world tracking, plane detection, current head pose, floor resolution.

RoomSkinningCoordinator
  Room scan and skinning flow.

WallPlaneManager
  Wall candidates from room tracking.

WallPropOccupancyRegistry
  Occupancy records for wall props. Add story radio / Turing prop occupancy here.

WallMountedPosterUIController
  Existing wall-snapped UI placement pattern.

PlagueOperationModePosterMenu
  Existing mode-selection UI surface.

PlagueHeadTrackedInstructionHUD
  Existing head-tracked HUD. Keep it for player dictation and instructions only.

GravitasDemoAudioController
  Existing spatial audio resource, emitter, and playback controller owner.

HordePortalManager and portal ingress types
  Existing portal placement and prop patterns.

JockRetargetTestController / Jock runtime classes
  Existing character animation runtime and sidecar audio emitter patterns.

PlagueDemoSession
  Story / Horde / Walk Loop operation mode split.
```

Integration rule:

Turing services run off-main and return rendered audio file references plus routing metadata. The MainActor adapter in `PlagueImmersiveCoordinator` attaches those files to the existing spatial audio path.

## 4. Module layout

Add a dedicated Turing module under the app target.

```text
Gravitas Plague/Gravitas Plague/Turing/
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

Resources:

```text
Resources/Turing/
  Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit/
  SpeechTokenizer/Qwen3-TTS-Tokenizer-12Hz/
  Voices/Library/
  Voices/Cloned/
  Prompts/
    voiceScript_exactSegmentation.txt
    voicePrompt_characterIntent.txt
    conversationPrompt_characterTurn.txt
    focusSummary_chunk.txt
    focusPrompt_characterSpeech.txt
    jsonRepair.txt
  Bibles/Episode01/
    catalog.json
    plague.txt
    big_mike.txt
    player_big_mike_relationship.txt
  Scripts/Prologue/
    prologue.json
    voiceScripts.json
  Config/
    model-registry.json
    voice-registry.json
    turing-runtime.json
```

Large model assets should be Git LFS or an equivalent asset pipeline. Every model asset directory needs a model identifier, revision, quantization, tokenizer reference, checksum manifest, and license metadata.

## 5. Runtime configuration

`Resources/Turing/Config/turing-runtime.json`:

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

## 6. Core data contracts

```swift
enum TuringAction: Sendable {
    case voiceScript(VoiceScriptRequest)
    case voicePrompt(VoicePromptRequest)
    case conversationPrompt(ConversationPromptRequest)
    case focusSummary(FocusSummaryRequest)
    case focusPrompt(FocusPromptRequest)
}
```

```swift
struct TuringSpeechSegment: Codable, Sendable, Hashable {
    let text: String
    let emotion: String
}

struct TuringDialoguePlan: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let segments: [TuringSpeechSegment]
    let focus: TuringFocusRequest?
}

struct TuringFocusRequest: Codable, Sendable, Hashable {
    let enabled: Bool
    let bibleID: String?
    let question: String?
    let bridgeSegments: [TuringSpeechSegment]
}

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

struct ChunkJob: Codable, Sendable, Hashable {
    let index: Int
    let offset: Int
    let end: Int
}
```

Playback routing is runtime-only:

```swift
enum TuringPlaybackTarget: Codable, Sendable, Hashable {
    case none
    case worldPosition(id: String)
    case prop(id: String)
    case character(id: String, anchor: String)
}

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

struct TuringRenderedSegment: Sendable, Hashable {
    let segmentIndex: Int
    let fileURL: URL
    let durationSeconds: TimeInterval
    let cacheKey: String
}

```

Do not send `TuringPlaybackTarget`, emitter IDs, HUD state, checkpoint state, unlock state, or RealityKit entity identifiers to Foundation Models unless the words themselves need to mention them.

## 7. Foundation Models runner

Every prompt uses a fresh session. Continuity comes from explicit external state assembled into the prompt.

```swift
actor FreshFoundationQueryRunner {
    enum RunnerError: LocalizedError {
        case unavailable
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Foundation Models are unavailable."
            case .emptyResponse:
                return "Foundation Models returned an empty response."
            }
        }
    }

    func respond(
        instructions: String,
        prompt: String
    ) async throws -> String {
        try Task.checkCancellation()

        #if GR_USE_FOUNDATION_MODELS && compiler(>=6.0) && canImport(FoundationModels)
        guard #available(visionOS 26.0, *) else {
            throw RunnerError.unavailable
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw RunnerError.unavailable
        }

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
        )
        let response = try await session.respond(to: prompt)
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else {
            throw RunnerError.emptyResponse
        }
        return content
        #else
        throw RunnerError.unavailable
        #endif
    }
}
```

Notes:

- Do not store `LanguageModelSession` on the actor.
- Do not reuse a chat transcript.
- Do not let a failed response fall through to code-authored dialogue.

## 8. JSON cleanup, gates, and repair

Turing JSON cleanup is mechanical only.

Allowed cleanup:

- Trim whitespace.
- Remove a single outer markdown fence if the entire response is fenced.
- Remove UTF-8 BOM.
- Remove invalid non-printing control characters.
- Extract one balanced top-level JSON object when extra wrapper prose exists.

Forbidden cleanup:

- Insert commas.
- Rename keys.
- Convert single quotes.
- Invent fields.
- Delete fields.
- Rewrite text or emotion.
- Extract one field and pretend the whole object was valid.

```swift
enum FoundationJSONSanitizer {
    static func sanitizeObject(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        text = removeSingleOuterFence(text)
        text = removeInvalidControlScalars(text)

        if let object = extractBalancedTopLevelObject(text) {
            return object.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    private static func removeSingleOuterFence(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2,
              lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true else {
            return text
        }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func removeInvalidControlScalars(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            scalar.value == 9 ||
            scalar.value == 10 ||
            scalar.value == 13 ||
            scalar.value >= 32
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func extractBalancedTopLevelObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaping = false
        var index = start

        while index < text.endIndex {
            let char = text[index]

            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }
}
```

Strict gates:

```swift
protocol FoundationJSONGate {
    associatedtype Payload: Decodable & Sendable
    func decode(_ json: String) throws -> Payload
    func validate(_ payload: Payload) throws
}

struct StrictJSONGate<Payload: Decodable & Sendable>: FoundationJSONGate {
    let validatePayload: @Sendable (Payload) throws -> Void

    func decode(_ json: String) throws -> Payload {
        guard let data = json.data(using: .utf8) else {
            throw TuringGateError.nonUTF8
        }
        let decoder = JSONDecoder()
        let payload = try decoder.decode(Payload.self, from: data)
        try validate(payload)
        return payload
    }

    func validate(_ payload: Payload) throws {
        try validatePayload(payload)
    }
}

enum TuringGateError: LocalizedError {
    case nonUTF8
    case emptySegments
    case invalidSchemaVersion
    case exactTextMismatch
    case invalidEmotion(String)
    case invalidProvenance
}
```

Repair:

```swift
actor FoundationRepairService {
    private let runner: FreshFoundationQueryRunner
    private let templates: FoundationPromptTemplateStore

    init(
        runner: FreshFoundationQueryRunner,
        templates: FoundationPromptTemplateStore
    ) {
        self.runner = runner
        self.templates = templates
    }

    func decodeOrRepair<G: FoundationJSONGate>(
        rawResponse: String,
        originalPrompt: String,
        gate: G,
        schemaDescription: String
    ) async throws -> G.Payload {
        let sanitized = FoundationJSONSanitizer.sanitizeObject(rawResponse)

        do {
            return try gate.decode(sanitized)
        } catch {
            let repairPrompt = try templates.render(
                name: "jsonRepair",
                values: [
                    "schemaDescription": schemaDescription,
                    "originalPrompt": originalPrompt,
                    "malformedOutput": rawResponse,
                    "decodeError": error.localizedDescription
                ]
            )

            let repairedRaw = try await runner.respond(
                instructions: "Return corrected JSON only. No markdown. No prose.",
                prompt: repairPrompt
            )
            let repairedSanitized = FoundationJSONSanitizer.sanitizeObject(repairedRaw)
            return try gate.decode(repairedSanitized)
        }
    }
}
```

No second repair in MVP unless product explicitly configures it. One original call plus one repair call is enough to avoid hiding broken prompts.

## 9. Prompt templates and sparse schemas

Store prompts as versioned text resources. The prompt renderer should substitute explicit values only; no hidden global chat memory.

### 9.1 `voiceScript_exactSegmentation.txt`

Use for authored exact dialogue or exact narration. This is the Turing-safe version of Crunch `TTSNarrationSegmentPlanner`.

```text
You are a speech segmentation planner for a story-mode text-to-speech pipeline.

Task:
Split the exact input text into natural spoken segments for TTS.

Hard requirements:
- Preserve the original text exactly.
- Do not paraphrase.
- Do not summarize.
- Do not rewrite.
- Do not reorder.
- Do not add words.
- Do not remove words.
- Do not change punctuation.
- Only choose segment boundaries.
- Each segment should sound natural when spoken aloud.
- Target 3 to 5 seconds per segment.
- Prefer complete phrases and clauses.
- Avoid splitting names, titles, dates, numbers, acronyms, quoted phrases, and parenthetical phrases.
- Every character from the input text must appear exactly once across `segments[*].spokenText` in the same order, ignoring only leading and trailing whitespace around each segment.
- Return JSON only. No markdown. No prose outside JSON.

Return this exact sparse JSON schema:
{
  "version": 1,
  "targetSeconds": 4.0,
  "maxSeconds": 5.0,
  "segments": [
    {
      "index": 0,
      "spokenText": "string"
    }
  ]
}

Input text:
"""
{{sourceText}}
"""
```

Gate rules:

- `version == 1`.
- `segments` is non-empty.
- `index` values are `0..<count`.
- `spokenText` values are non-empty after trim.
- `segments.map(\.spokenText).joined(separator: " ")` must normalize to the exact normalized source text.
- If the gate fails, run `jsonRepair`.
- If repair fails, fail the action.

### 9.2 `voicePrompt_characterIntent.txt`

Use when the script supplies intent rather than exact text.

```text
You are writing one short spoken turn for a character in Gravitas Plague.

Character:
{{characterProfile}}

Voice direction:
{{emotion}}

Story intent:
{{intent}}

Rules:
- Write only the character's spoken words.
- Keep the response in character.
- Do not mention game systems, prompts, routing, files, props, HUD, or model behavior.
- Segment the speech into natural 3 to 5 second TTS segments.
- Every segment must include an emotion label.
- Use the requested emotion unless the character profile and intent clearly require a more specific adjacent emotion.
- Return JSON only. No markdown. No prose outside JSON.

Return this exact sparse JSON schema:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "string",
      "emotion": "string"
    }
  ]
}
```

### 9.3 `conversationPrompt_characterTurn.txt`

Use for a player dictation turn.

```text
You are the active story character in Gravitas Plague.

Character:
{{characterProfile}}

Current episode state:
{{episodeStateForWordsOnly}}

Player said:
"""
{{playerDictation}}
"""

Available Bible catalog metadata:
{{bibleCatalogJSON}}

Rules:
- Respond as the character, not as an assistant.
- Do not describe hidden systems.
- Do not include stage directions.
- Do not mention audio, Qwen, MLX, Foundation Models, prompts, caches, files, or JSON.
- If the player asks something requiring deeper Bible knowledge, set `focus.enabled` to true and ask for the exact Bible and question.
- If no deeper Bible knowledge is needed, set `focus.enabled` to false.
- You may include short bridgeSegments while Focus is computed.
- Segment all speech into natural 3 to 5 second TTS segments.
- Return a comprehensive 5-6 segment response answering the player to the best of your knowledge
- Return JSON only. No markdown. No prose outside JSON.

Return this exact sparse JSON schema:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "string",
      "emotion": "string"
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

### 9.4 `focusSummary_chunk.txt`

Use for independent Bible chunks. This is the Crunch Focus Mode pattern, simplified for Turing.

```text
You are processing one source chunk for a story character's Bible query.

Question:
{{question}}

Chunk label:
Chunk {{chunkNumber}} of {{totalChunks}}, absolute UTF-16 offsets {{offsetStart}}-{{offsetEnd}}

Budget:
Return <= {{budgetCharacters}} characters.

Rules:
- Use only facts present in this chunk.
- Focus on information relevant to the question.
- Do not answer from outside knowledge.
- Do not mention chunks, prompts, datasets, or models in the summary.
- Return JSON only. No markdown. No prose outside JSON.

Return this exact sparse JSON schema:
{
  "schemaVersion": 1,
  "summary": "string",
  "supportingChunks": [
    {
      "chunkIndex": 0,
      "absoluteStart": 0,
      "absoluteEnd": 0
    }
  ]
}

Chunk text:
"""
{{chunkText}}
"""
```

### 9.5 `focusPrompt_characterSpeech.txt`

Use after Focus summaries have been reduced into final evidence.

```text
You are converting Bible evidence into one character-spoken response.

Character:
{{characterProfile}}

Question:
{{question}}

Evidence:
{{focusSummaryJSON}}

Rules:
- Respond as the character.
- Ground the answer in the evidence.
- Do not mention chunks, JSON, prompts, datasets, or models.
- Do not include citations in spoken text.
- Segment the speech into natural 3 to 5 second TTS segments.
- Return JSON only. No markdown. No prose outside JSON.

Return this exact sparse JSON schema:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "string",
      "emotion": "string"
    }
  ]
}
```

### 9.6 `jsonRepair.txt`

```text
Your previous output failed JSON parsing or schema validation.

Return corrected JSON only.
No markdown.
No prose outside JSON.
Do not add new story content.
Do not remove required content.
Do not rewrite the intended spoken words except when required to produce valid JSON escaping.
Do not change emotion labels unless the schema requires a non-empty value.

Required schema:
{{schemaDescription}}

Original prompt:
"""
{{originalPrompt}}
"""

Malformed output:
"""
{{malformedOutput}}
"""

Decode or validation error:
{{decodeError}}
```

## 10. Chunking and parallel LLM processing

Transport chunking is deterministic because it is mechanical, not semantic. Foundation Models decides summaries and speech phrasing, not initial Bible chunk boundaries.

```swift
enum TokenEstimator {
    static func estimateTokens(in text: String) -> Int {
        max(1, text.utf16.count / 4)
    }
}

enum UTF16ChunkingUtilities {
    static func substring(_ text: String, start: Int, end: Int) -> String {
        guard start < end else { return "" }
        let safeStart = max(start, 0)
        let safeEnd = min(end, text.utf16.count)
        guard safeStart < safeEnd else { return "" }
        let startIndex = String.Index(utf16Offset: safeStart, in: text)
        let endIndex = String.Index(utf16Offset: safeEnd, in: text)
        return String(text[startIndex..<endIndex])
    }

    static func makeChunkJobs(totalLength: Int, chunkSize: Int) -> [ChunkJob] {
        guard chunkSize > 0 else { return [] }
        var jobs: [ChunkJob] = []
        var offset = 0
        var index = 0

        while offset < totalLength {
            let end = min(totalLength, offset + chunkSize)
            jobs.append(ChunkJob(index: index, offset: offset, end: end))
            offset = end
            index += 1
        }

        if jobs.isEmpty {
            jobs.append(ChunkJob(index: 0, offset: 0, end: totalLength))
        }

        return jobs
    }
}
```

Bounded parallel limiter:

```swift
actor FocusChunkConcurrencyLimiter {
    enum WaitPriority: Sendable {
        case high
        case normal
    }

    nonisolated let maxConcurrentTasks: Int
    private var availablePermits: Int
    private var highPriorityWaiters: [CheckedContinuation<Void, Never>] = []
    private var normalPriorityWaiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentTasks: Int) {
        let clamped = max(1, maxConcurrentTasks)
        self.maxConcurrentTasks = clamped
        self.availablePermits = clamped
    }

    func acquire(priority: WaitPriority = .normal) async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            switch priority {
            case .high:
                highPriorityWaiters.append(continuation)
            case .normal:
                normalPriorityWaiters.append(continuation)
            }
        }
    }

    func release() {
        if highPriorityWaiters.isEmpty && normalPriorityWaiters.isEmpty {
            availablePermits += 1
            return
        }

        let continuation: CheckedContinuation<Void, Never>
        if highPriorityWaiters.isEmpty == false {
            continuation = highPriorityWaiters.removeFirst()
        } else {
            continuation = normalPriorityWaiters.removeFirst()
        }
        continuation.resume()
    }

    func withPermit<T: Sendable>(
        priority: WaitPriority = .normal,
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(priority: priority)
        defer { release() }
        return try await operation()
    }
}
```

Focus summary service:

```swift
actor TuringFocusSummaryService {
    private let runner: FreshFoundationQueryRunner
    private let repair: FoundationRepairService
    private let templates: FoundationPromptTemplateStore
    private let limiter: FocusChunkConcurrencyLimiter
    private let config: TuringRuntimeConfig

    init(
        runner: FreshFoundationQueryRunner,
        repair: FoundationRepairService,
        templates: FoundationPromptTemplateStore,
        limiter: FocusChunkConcurrencyLimiter,
        config: TuringRuntimeConfig
    ) {
        self.runner = runner
        self.repair = repair
        self.templates = templates
        self.limiter = limiter
        self.config = config
    }

    func buildAggregate(
        fullText: String,
        bibleID: String,
        question: String,
        priority: FocusChunkConcurrencyLimiter.WaitPriority = .high
    ) async throws -> [TuringFocusSummaryResult] {
        let normalized = normalize(fullText)
        guard normalized.isEmpty == false else {
            throw TuringFocusError.emptyBible
        }

        let totalLength = normalized.utf16.count
        let estimatedTokens = TokenEstimator.estimateTokens(in: normalized)
        let targetChunkCount = max(
            1,
            Int(ceil(Double(estimatedTokens) / Double(config.foundation.maxChunkTokens)))
        )
        let chunkSizeUTF16 = max(
            1,
            Int(ceil(Double(totalLength) / Double(targetChunkCount)))
        )
        let jobs = UTF16ChunkingUtilities.makeChunkJobs(
            totalLength: totalLength,
            chunkSize: chunkSizeUTF16
        )

        let budgetPerChunk = Int(ceil(
            Double(config.foundation.aggregateBudgetTokens) / Double(jobs.count)
        ))
        let budgetCharacters = max(
            64,
            budgetPerChunk * 4 - config.foundation.perChunkMetadataOverheadCharacters
        )

        let summaries = try await runChunkSummaries(
            jobs: jobs,
            text: normalized,
            bibleID: bibleID,
            question: question,
            budgetCharacters: budgetCharacters,
            priority: priority
        )

        return try await reduceUntilFits(
            summaries,
            bibleID: bibleID,
            question: question,
            priority: priority
        )
    }

    private func runChunkSummaries(
        jobs: [ChunkJob],
        text: String,
        bibleID: String,
        question: String,
        budgetCharacters: Int,
        priority: FocusChunkConcurrencyLimiter.WaitPriority
    ) async throws -> [TuringFocusSummaryResult] {
        let gate = StrictJSONGate<TuringFocusSummaryResult> { payload in
            guard payload.schemaVersion == 1 else {
                throw TuringGateError.invalidSchemaVersion
            }
            guard payload.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw TuringFocusError.emptySummary
            }
        }

        return try await withThrowingTaskGroup(
            of: (Int, TuringFocusSummaryResult).self
        ) { group in
            for job in jobs {
                group.addTask {
                    try await self.limiter.withPermit(priority: priority) {
                        let chunk = UTF16ChunkingUtilities.substring(
                            text,
                            start: job.offset,
                            end: job.end
                        )
                        let prompt = try await self.templates.render(
                            name: "focusSummary_chunk",
                            values: [
                                "bibleID": bibleID,
                                "question": question,
                                "chunkNumber": "\(job.index + 1)",
                                "totalChunks": "\(jobs.count)",
                                "offsetStart": "\(job.offset)",
                                "offsetEnd": "\(job.end)",
                                "budgetCharacters": "\(budgetCharacters)",
                                "chunkText": chunk
                            ]
                        )
                        let raw = try await self.runner.respond(
                            instructions: "Return strict JSON only.",
                            prompt: prompt
                        )
                        let decoded = try await self.repair.decodeOrRepair(
                            rawResponse: raw,
                            originalPrompt: prompt,
                            gate: gate,
                            schemaDescription: TuringSchemas.focusSummary
                        )
                        return (job.index, decoded)
                    }
                }
            }

            var results: [(Int, TuringFocusSummaryResult)] = []
            results.reserveCapacity(jobs.count)

            for try await result in group {
                results.append(result)
            }

            return results
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private func reduceUntilFits(
        _ summaries: [TuringFocusSummaryResult],
        bibleID: String,
        question: String,
        priority: FocusChunkConcurrencyLimiter.WaitPriority
    ) async throws -> [TuringFocusSummaryResult] {
        var current = summaries

        while TokenEstimator.estimateTokens(in: aggregateJSON(current)) >
            config.foundation.aggregateBudgetTokens {
            current = try await reduceOneLayer(
                current,
                bibleID: bibleID,
                question: question,
                priority: priority
            )
        }

        return current
    }

    private func reduceOneLayer(
        _ summaries: [TuringFocusSummaryResult],
        bibleID: String,
        question: String,
        priority: FocusChunkConcurrencyLimiter.WaitPriority
    ) async throws -> [TuringFocusSummaryResult] {
        let groups = FocusChunkAggregator.makeTokenSafeGroups(
            summaries,
            maxTokens: config.foundation.aggregateBudgetTokens
        )

        return try await withThrowingTaskGroup(
            of: (Int, TuringFocusSummaryResult).self
        ) { group in
            for (groupIndex, groupSummaries) in groups.enumerated() {
                group.addTask {
                    try await self.limiter.withPermit(priority: priority) {
                        let prompt = try await self.templates.render(
                            name: "focusSummary_reduce",
                            values: [
                                "bibleID": bibleID,
                                "question": question,
                                "summaryGroupJSON": aggregateJSON(groupSummaries)
                            ]
                        )
                        let raw = try await self.runner.respond(
                            instructions: "Return strict JSON only.",
                            prompt: prompt
                        )
                        let gate = StrictJSONGate<TuringFocusSummaryResult> { payload in
                            guard payload.schemaVersion == 1 else {
                                throw TuringGateError.invalidSchemaVersion
                            }
                            guard payload.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                                throw TuringFocusError.emptySummary
                            }
                        }
                        let decoded = try await self.repair.decodeOrRepair(
                            rawResponse: raw,
                            originalPrompt: prompt,
                            gate: gate,
                            schemaDescription: TuringSchemas.focusSummary
                        )
                        return (groupIndex, decoded)
                    }
                }
            }

            var reduced: [(Int, TuringFocusSummaryResult)] = []
            for try await result in group {
                reduced.append(result)
            }

            return reduced
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Parallel reduction rule:

- If the ordered aggregate is too large, split summaries into token-safe groups.
- Reduce each group through independent Foundation Models calls.
- Run those group reductions through the same bounded limiter.
- Sort reduced groups back into original order.
- Repeat until the aggregate fits `aggregateBudgetTokens`.
- The final Focus answer is produced by `focusPrompt_characterSpeech`.

No code-authored summarization is allowed at any reduction layer.

## 11. Speech segmentation flow

There are two speech paths:

1. Exact text: run `voiceScript_exactSegmentation` through Foundation Models.
2. Generated text: the generating prompt returns speech segments directly.

Exact text segmentation:

```swift
actor TuringSpeechSegmentationService {
    private let runner: FreshFoundationQueryRunner
    private let repair: FoundationRepairService
    private let templates: FoundationPromptTemplateStore

    func segmentExactSpeech(
        sourceText: String
    ) async throws -> [TuringSpeechSegment] {
        let normalized = normalizeForExactCoverage(sourceText)
        guard normalized.isEmpty == false else {
            throw TuringSpeechError.emptyText
        }

        let prompt = try await templates.render(
            name: "voiceScript_exactSegmentation",
            values: ["sourceText": normalized]
        )
        let raw = try await runner.respond(
            instructions: "Return strict JSON only.",
            prompt: prompt
        )

        let gate = StrictJSONGate<ExactSpeechSegmentationPayload> { payload in
            guard payload.version == 1 else {
                throw TuringGateError.invalidSchemaVersion
            }
            guard payload.segments.isEmpty == false else {
                throw TuringGateError.emptySegments
            }
            let joined = payload.segments
                .map { $0.spokenText.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
            guard normalizeForExactCoverage(joined) == normalized else {
                throw TuringGateError.exactTextMismatch
            }
        }

        let payload = try await repair.decodeOrRepair(
            rawResponse: raw,
            originalPrompt: prompt,
            gate: gate,
            schemaDescription: TuringSchemas.exactSpeechSegmentation
        )

        return payload.segments.map {
            TuringSpeechSegment(text: $0.spokenText, emotion: "neutral")
        }
    }
}

struct ExactSpeechSegmentationPayload: Codable, Sendable {
    let version: Int
    let targetSeconds: Double
    let maxSeconds: Double
    let segments: [Segment]

    struct Segment: Codable, Sendable {
        let index: Int
        let spokenText: String
    }
}

func normalizeForExactCoverage(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\n", with: " ")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { $0.isEmpty == false }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
```

Generated speech gates:

- `schemaVersion == 1`.
- `segments` is non-empty.
- `text` is non-empty after trim.
- `emotion` is non-empty after trim and belongs to the configured emotion vocabulary, or the vocabulary gate is disabled.
- `focus.enabled == true` requires `bibleID` and `question`.
- `focus.enabled == false` requires `bibleID == nil` and `question == nil`.
- `bridgeSegments` must pass the same speech segment gate.

If any gate fails, use Foundation Models repair. If repair fails, fail the action.

## 11A. Audiobook Mode Text Splitting: Current Contract

Audiobook mode is the arbitrary-length text path. The active implementation has two separate splitting layers:

1. Source sectioning: mechanical transport split with stable UTF-16 offsets. This is allowed because it only creates prompt-sized source sections. It does not decide spoken TTS phrasing.
2. Spoken segmentation: Foundation Models receives one source section and chooses natural spoken TTS segments. Runtime code does not replace this with punctuation, sentence, word-count, or character-count speech splitting.

Do not collapse these layers. Source sections are only the amount of source text sent to Foundation at one time. Spoken segments are the text sent to Qwen.

### 11A.1 Source Section Policy

Use this policy for mechanical source sectioning:

```swift
struct TuringAudiobookSourceSectionPolicy: Sendable, Equatable {
    let targetWords: Int = 120
    let minWords: Int = 45
    let maxWords: Int = 210
    let maxChars: Int = 2400
}
```

### 11A.2 Source Sectioning Rules

1. Normalize source text.
2. Enumerate by paragraphs.
3. Trim paragraph ranges while preserving UTF-16 offsets.
4. Count words.
5. If paragraph `wordCount > 210` or UTF-16 length is greater than `2400`, enumerate that paragraph by sentences as transport units.
6. Pack units into sections.
7. Start a new section only when:

```text
currentWordCount >= 45
AND
(
  currentWordCount >= 120
  OR currentWordCount + nextUnit.wordCount > 210
  OR currentUTF16Length + nextUnitUTF16Length > 2400
)
```

8. Each source section stores:

```text
index
sourceStartUTF16
sourceEndUTF16
estimatedWordCount
```

The runner should log each planned section, including the actual section text, before sending Foundation work. Those logs are diagnostic visibility, not gates.

### 11A.3 Foundation Spoken Segmentation

For each source section:

- Use a fresh Foundation Models session.
- Send only that section text.
- Ask the model to return ordered spoken segments.
- The prompt tells the model to cover the full section, preserve order, target 3 to 5 seconds per segment, avoid tiny segments, split long sentences naturally, and return JSON only.
- Runtime does not verify those semantic requirements. The prompt owns phrasing correctness.
- Run sections through a rolling window, not an all-sections upfront batch.
- Recommended default: one Foundation section request in flight. Optional lookahead may add one extra request only when the device budget allows.
- Priority is current section, then next section, then optional lookahead.
- Each LLM call receives previous context tail, section text, and next context head. The context is read-only; only section text is segmentable.

The current sparse JSON shape is:

```json
{
  "schemaVersion": 1,
  "sectionIndex": 0,
  "segments": [
    {
      "index": 0,
      "spokenText": "string sent to TTS",
      "emotion": "narration"
    }
  ]
}
```

Do not require a returned `sourceText` field. The app's input text for one job is called section text in logs and prompts.

### 11A.4 Rolling Window LLM Compute

Audiobook mode must not send the whole book to Foundation Models and must not precompute the entire book upfront.

Use a rolling section window:

```text
currentSection  = section being spoken or about to be spoken
nextSection     = section being segmented by Foundation while current audio plays
lookahead       = optional section after next, only when runtime budget allows
```

Default window:

```text
Window size: 2 sections

N     = active playback / active Qwen sequential synthesis
N + 1 = Foundation Models spoken segmentation in flight or ready
```

Optional low-priority window:

```text
Window size: 3 sections max

N     = active playback / active Qwen sequential synthesis
N + 1 = high-priority Foundation segmentation
N + 2 = low-priority Foundation segmentation only when idle
```

Runtime state:

```swift
struct TuringAudiobookRollingWindowState: Sendable {
    var activeSectionIndex: Int
    var activeSegmentIndex: Int
    var highestPreparedSectionIndex: Int
    var llmInFlightSectionIndices: Set<Int>
    var preparedSectionIndices: Set<Int>
    var qwenInFlight: Bool
}
```

Scheduling priority:

```text
1. current section missing parsed segments
2. next section missing parsed segments
3. optional lookahead section
```

Do not launch Foundation jobs for every section. The rolling window exists to keep memory, Foundation scheduling, and Qwen playback predictable.

Foundation prompt window per section:

```text
previousContextTail: last 300-600 characters of previous section, read-only
sectionText:         the only text the model should segment
nextContextHead:     first 300-600 characters of next section, read-only
```

Context is only for continuity at section edges. The model may use it to avoid awkward starts and endings, but it must only return spoken segments for `sectionText`.

Prompt payload shape:

```json
{
  "sectionIndex": 12,
  "previousContextTail": "read-only tail from section 11",
  "sectionText": "the exact source section to segment",
  "nextContextHead": "read-only head from section 13"
}
```

Rolling compute flow:

```text
1. Normalize full audiobook text once.
2. Mechanically create UTF-16 source sections once.
3. Start Foundation segmentation for section 0.
4. When section 0 JSON parses, begin sequential Qwen synthesis/playback for section 0.
5. As soon as section 0 has parsed segments, start Foundation segmentation for section 1.
6. While Qwen speaks section 0 segments, Foundation computes section 1.
7. When section 0 completes:
   - if section 1 is ready, continue immediately;
   - if section 1 is not ready, wait;
   - do not create filler;
   - do not deterministic-split section 1.
8. Repeat for section N.
```

Pseudocode:

```swift
func runAudiobook() async throws {
    try await ensureFoundationPrepared(sectionIndex: 0, priority: .high)

    while let section = currentSection {
        try await ensureFoundationPrepared(sectionIndex: section.index, priority: .high)

        scheduleFoundationIfNeeded(
            sectionIndex: section.index + 1,
            priority: .high
        )

        scheduleFoundationIfBudgetAllows(
            sectionIndex: section.index + 2,
            priority: .low
        )

        let prepared = try await preparedSection(section.index)

        for segment in prepared.segments {
            try await qwenSequentiallySynthesizeAndPlay(segment)

            scheduleFoundationIfNeeded(
                sectionIndex: section.index + 1,
                priority: .high
            )
        }

        advanceToNextSection()
    }
}
```

Concurrency rules:

- Foundation segmentation may run ahead within the rolling window.
- Foundation repair for malformed JSON counts against the same Foundation concurrency budget.
- Qwen synthesis remains strictly sequential.
- Playback remains ordered by section index and segment order returned by JSON.
- Lookahead work must cancel or yield if the active or next section needs Foundation.
- If the user jumps to another section, cancel stale lookahead and prioritize the new active section.

No semantic gates are added to this rolling window. A ready section means "JSON parsed into the sparse payload," not "runtime proved source coverage."

### 11A.5 JSON Handling Rule

Runtime only checks whether the model response can be decoded as the sparse JSON payload.

If JSON parses:

- accept it;
- read `segments` in returned order;
- default missing or blank emotion to `narration`;
- send `spokenText` values sequentially to Qwen.

If JSON does not parse:

1. Do mechanical cleanup through the JSON sanitizer.
2. Try JSON parse again.
3. If still malformed, send malformed output to a fresh Foundation Models JSON repair prompt.
4. Parse repaired JSON.
5. If repaired JSON still does not parse, fail the section before Qwen.

### 11A.6 No Semantic Gates

Do not gate or repair valid JSON for:

- exact source coverage;
- segment count;
- segment duration;
- segment index order;
- duplicate text;
- missing text;
- added text;
- rewritten text;
- empty emotion;
- one-word segments;
- tiny final segments.

Those are prompt responsibilities only.

### 11A.7 Sequential TTS

After JSON parses:

1. Emit source sections to Qwen in source order as each ordered section becomes available from the rolling Foundation window.
2. Iterate each section's returned segments in order.
3. For each segment, create a fresh Qwen synthesis session, synthesize the segment, release segment-local state, and hand generated audio to the compute-gap audio coordinator.
4. Continue until the section is complete, then continue to the next available ordered section.
5. Qwen generation remains one segment at a time.
6. Foundation segmentation for section `N + 1` may continue while Qwen renders or plays section `N`.
7. No packets.
8. No packet-zero behavior.
9. No split-in-half behavior.
10. No filler in audiobook mode. If the next section is not ready when the current section finishes, wait.

The active implementation does not reintroduce a persistent generated-WAV cache. Temporary playback files or in-memory generated audio may be used by the existing playback system, then cleaned up.

### 11A.8 Failure Rule

Only fail audiobook mode for:

- Foundation Models unavailable;
- malformed JSON after repair;
- TTS model failure;
- audio playback/coordinator failure.

Do not fail because Foundation made a bad segmentation choice. Do not repair valid JSON for semantic reasons. Do not use deterministic fallback speech splitting.

## 12. Qwen MLX TTS layer

Qwen MVP constraints:

- Target model: `Qwen3-TTS-12Hz-1.7B-Base`, 4-bit quantization.
- MLX on Apple GPU only.
- Shared immutable weights may remain resident.
- Fresh request-local synthesis session per spoken segment.
- Sequential renders only.
- No batching in MVP.
- No CPU fallback.
- No Python.
- No PyTorch.

Model host protocol:

```swift
protocol QwenTTSModelHost: Sendable {
    var modelID: String { get }
    var modelRevision: String { get }
    var quantization: String { get }
    var tokenizerRevision: String { get }

    func loadIfNeeded() async throws
    func assertGPUAvailable() async throws
    func makeSession() async throws -> QwenTTSSynthesisSession
}

protocol QwenTTSSynthesisSession: Sendable {
    func synthesize(
        text: String,
        emotion: String,
        voice: TuringVoiceDescriptor,
        settings: QwenGenerationSettings
    ) async throws -> QwenWaveform

    func releaseTransientState() async
}
```

Sequential scheduler:

```swift
actor QwenTTSSequentialScheduler {
    private let host: QwenTTSModelHost
    private let cache: TuringAudioCache
    private let fileWriter: TuringAudioFileWriter
    private let settings: QwenGenerationSettings

    init(
        host: QwenTTSModelHost,
        cache: TuringAudioCache,
        fileWriter: TuringAudioFileWriter,
        settings: QwenGenerationSettings
    ) {
        self.host = host
        self.cache = cache
        self.fileWriter = fileWriter
        self.settings = settings
    }

    func render(
        segment: TuringSpeechSegment,
        segmentIndex: Int,
        voice: TuringVoiceDescriptor,
        radioTreatment: TuringRadioEffectProfile?
    ) async throws -> TuringRenderedSegment {
        try Task.checkCancellation()

        let key = try cache.key(
            segment: segment,
            voice: voice,
            model: host,
            settings: settings,
            radioTreatment: radioTreatment
        )

        if let cached = try await cache.lookup(key: key) {
            return TuringRenderedSegment(
                segmentIndex: segmentIndex,
                fileURL: cached.fileURL,
                durationSeconds: cached.durationSeconds,
                cacheKey: key
            )
        }

        try await host.assertGPUAvailable()
        try await host.loadIfNeeded()

        let session = try await host.makeSession()
        let waveform: QwenWaveform

        do {
            waveform = try await session.synthesize(
                text: segment.text,
                emotion: segment.emotion,
                voice: voice,
                settings: settings
            )
        } catch {
            await session.releaseTransientState()
            throw error
        }

        await session.releaseTransientState()

        let file = try await fileWriter.write(
            waveform: waveform,
            cacheKey: key
        )
        try await cache.store(file: file, key: key)

        return TuringRenderedSegment(
            segmentIndex: segmentIndex,
            fileURL: file.fileURL,
            durationSeconds: file.durationSeconds,
            cacheKey: key
        )
    }
}
```

Implementation note:

The MLX API shape will depend on the Swift/MLX package selected for the app target. The production adapter must make `assertGPUAvailable()` a hard gate. A failed GPU requirement is a user-visible Turing error, not an automatic CPU path.

## 13. Audio cache identity

Cache keys must invalidate whenever anything material to sound changes.

```swift
actor TuringAudioCache {
    private let rootURL: URL

    func key(
        segment: TuringSpeechSegment,
        voice: TuringVoiceDescriptor,
        model: QwenTTSModelHost,
        settings: QwenGenerationSettings,
        radioTreatment: TuringRadioEffectProfile?
    ) throws -> String {
        let payload = TuringAudioCacheIdentity(
            schemaVersion: 1,
            modelID: model.modelID,
            modelRevision: model.modelRevision,
            quantization: model.quantization,
            tokenizerRevision: model.tokenizerRevision,
            voiceID: voice.id,
            voiceRevision: voice.revision,
            text: segment.text,
            emotion: segment.emotion,
            language: settings.language,
            sampleRate: settings.sampleRate,
            temperature: settings.temperature,
            topP: settings.topP,
            seed: settings.seed,
            radioTreatmentID: radioTreatment?.id,
            radioTreatmentRevision: radioTreatment?.revision
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct TuringAudioCacheIdentity: Codable, Sendable {
    let schemaVersion: Int
    let modelID: String
    let modelRevision: String
    let quantization: String
    let tokenizerRevision: String
    let voiceID: String
    let voiceRevision: String?
    let text: String
    let emotion: String
    let language: String
    let sampleRate: Int
    let temperature: Double
    let topP: Double
    let seed: UInt64?
    let radioTreatmentID: String?
    let radioTreatmentRevision: String?
}
```

Cache file layout:

```text
Library/Caches/TuringAudio/
  qwen3-tts-12hz-1.7b-base-4bit/
    <cacheKey>.wav
    <cacheKey>.json
```

Metadata JSON should include duration, sample rate, channel count, creation date, cache identity, and source text.

## 14. Sequential segment compute-ahead pipeline

The new model path has segments, not packets.

Rules:

- `0` segments: fail.
- Iterate returned segments in order.
- Qwen renders one segment at a time.
- Each segment uses a fresh Qwen synthesis session.
- Segment-local synthesis state is released immediately after the segment is rendered.
- Playback is ordered by section index and segment order.
- Foundation Models may compute the next audiobook section while Qwen renders or playback speaks the current section.
- No packet grouping.
- No packet-zero rule.
- No split-in-half rule.

Speech pipeline:

```swift
actor TuringSpeechPipeline {
    enum Event: Sendable {
        case segmentRenderBegan(sectionIndex: Int?, segmentIndex: Int)
        case segmentReady(TuringRenderedSegment)
        case segmentRenderFinished(sectionIndex: Int?, segmentIndex: Int)
        case playbackCanStart(TuringRenderedSegment)
        case failed(String)
    }

    private let tts: QwenTTSSequentialScheduler

    init(tts: QwenTTSSequentialScheduler) {
        self.tts = tts
    }

    func renderSequentiallyForPlayback(
        sectionIndex: Int?,
        segments: [TuringSpeechSegment],
        voice: TuringVoiceDescriptor,
        radioTreatment: TuringRadioEffectProfile?,
        onEvent: @escaping @Sendable (Event) async -> Void
    ) async throws -> [TuringRenderedSegment] {
        guard segments.isEmpty == false else {
            throw TuringSpeechError.emptySegments
        }

        var rendered: [TuringRenderedSegment] = []
        rendered.reserveCapacity(segments.count)

        for index in segments.indices {
            try Task.checkCancellation()
            await onEvent(
                .segmentRenderBegan(
                    sectionIndex: sectionIndex,
                    segmentIndex: index
                )
            )

            let renderedSegment = try await tts.render(
                segment: segments[index],
                segmentIndex: index,
                voice: voice,
                radioTreatment: radioTreatment
            )

            rendered.append(renderedSegment)
            await onEvent(.segmentReady(renderedSegment))

            if index == 0 {
                await onEvent(.playbackCanStart(renderedSegment))
            }

            await onEvent(
                .segmentRenderFinished(
                    sectionIndex: sectionIndex,
                    segmentIndex: index
                )
            )
        }

        return rendered
    }
}
```

Playback adapter:

```swift
@MainActor
protocol TuringSpatialAudioAdapter {
    func playSegment(
        _ segment: TuringRenderedSegment,
        target: TuringPlaybackTarget
    ) async throws

    func enqueueSegment(
        _ segment: TuringRenderedSegment,
        after previousSegment: TuringRenderedSegment,
        target: TuringPlaybackTarget
    ) async throws
}
```

Plague implementation should wrap `GravitasDemoAudioController`, adding a method that can create an `AudioFileResource` from a cache file URL and play it from:

- the wall radio prop emitter
- the character head emitter
- a world-position entity
- the existing radio entity

If `AudioFileResource.load` cannot load from a generated file URL directly in the chosen visionOS SDK, the adapter should copy the file into an app-owned playback-safe location and load it there. That is file IO, not fallback.

## 15. Action flows

### 15.1 `voiceScript`

Use for exact authored script lines.

Flow:

1. Script runtime sends `VoiceScriptRequest`.
2. Load exact text and speaker voice.
3. Run `voiceScript_exactSegmentation` through a fresh Foundation Models session.
4. Sanitize, gate, repair once if needed.
5. Convert to `[TuringSpeechSegment]` with authored emotion.
6. Render segments sequentially through Qwen.
7. MainActor starts spatial playback when the first segment is ready.
8. Continue rendering and enqueueing later segments in order.

Failure:

- If segmentation fails after repair, fail the script command.
- If Qwen GPU unavailable, fail the command.
- If cache read/write fails, fail the command unless the system can retry the same Qwen render without changing content.

### 15.2 `voicePrompt`

Use when the script supplies a character intent.

Flow:

1. Script runtime sends `VoicePromptRequest`.
2. Load character profile, emotion, voice, intent.
3. Run `voicePrompt_characterIntent` through a fresh Foundation Models session.
4. Gate and repair.
5. Send returned segments to the sequential speech pipeline.

### 15.3 `conversationPrompt`

Use when the player speaks.

Flow:

1. Dictation coordinator captures player words.
2. Existing HUD shows only the player's dictated words.
3. Build prompt from player dictation, character profile, episode state that affects words, and Bible catalog metadata.
4. Run `conversationPrompt_characterTurn` through a fresh Foundation Models session.
5. Gate and repair.
6. If `focus.enabled == false`, speak `segments`.
7. If `focus.enabled == true`, speak `focus.bridgeSegments` immediately when present.
8. Load the requested Bible.
9. Run Focus chunk summaries in bounded parallel.
10. Reduce aggregate until it fits.
11. Run `focusPrompt_characterSpeech`.
12. Speak final Focus response.

Failure:

- If Focus fails, the current action fails. Do not invent a generic apology in code.
- If product wants an apology, it must be generated by a separate Foundation Models prompt and gated like every other line.

### 15.4 `focusSummary`

Use for Bible summarization only.

Flow:

1. Normalize Bible text mechanically.
2. Estimate tokens using UTF-16 / 4.
3. Compute target chunk count from `maxChunkTokens`.
4. Create `ChunkJob` records by UTF-16 offsets.
5. Run each chunk prompt independently through bounded Foundation Models calls.
6. Gate and repair each chunk independently.
7. Sort by chunk index.
8. Reduce aggregate through more Foundation Models calls if over budget.

### 15.5 `focusPrompt`

Use to convert Focus evidence into character speech.

Flow:

1. Build prompt from character profile, question, and Focus result JSON.
2. Fresh Foundation Models session.
3. Gate and repair.
4. Send segments to the sequential Qwen speech pipeline.

## 16. Coordinator skeleton

```swift
actor TuringCoordinator {
    private let segmentation: TuringSpeechSegmentationService
    private let dialogue: TuringDialogueService
    private let focusSummary: TuringFocusSummaryService
    private let focusPrompt: TuringFocusPromptService
    private let speechPipeline: TuringSpeechPipeline
    private let voices: TuringVoiceRegistry

    func handle(
        _ action: TuringAction,
        playbackTarget: TuringPlaybackTarget,
        onPlaybackEvent: @escaping @Sendable (TuringPlaybackEvent) async -> Void
    ) async throws -> TuringActionResult {
        switch action {
        case .voiceScript(let request):
            let voice = try await voices.voice(id: request.voiceID)
            let segments = try await segmentation.segmentExactSpeech(
                sourceText: request.text
            ).map {
                TuringSpeechSegment(text: $0.text, emotion: request.emotion)
            }
            let renderedSegments = try await speechPipeline.renderSequentiallyForPlayback(
                sectionIndex: nil,
                segments: segments,
                voice: voice,
                radioTreatment: request.radioTreatment,
                onEvent: makeSpeechEventBridge(
                    target: playbackTarget,
                    onPlaybackEvent: onPlaybackEvent
                )
            )
            return .spoken(renderedSegments)

        case .voicePrompt(let request):
            let plan = try await dialogue.generateVoicePrompt(request)
            let voice = try await voices.voice(id: request.voiceID)
            let renderedSegments = try await speechPipeline.renderSequentiallyForPlayback(
                sectionIndex: nil,
                segments: plan.segments,
                voice: voice,
                radioTreatment: request.radioTreatment,
                onEvent: makeSpeechEventBridge(
                    target: playbackTarget,
                    onPlaybackEvent: onPlaybackEvent
                )
            )
            return .spoken(renderedSegments)

        case .conversationPrompt(let request):
            return try await handleConversation(
                request,
                playbackTarget: playbackTarget,
                onPlaybackEvent: onPlaybackEvent
            )

        case .focusSummary(let request):
            let summaries = try await focusSummary.buildAggregate(
                fullText: request.bibleText,
                bibleID: request.bibleID,
                question: request.question,
                priority: .high
            )
            return .focusSummary(summaries)

        case .focusPrompt(let request):
            let plan = try await focusPrompt.generateSpeech(request)
            let voice = try await voices.voice(id: request.voiceID)
            let renderedSegments = try await speechPipeline.renderSequentiallyForPlayback(
                sectionIndex: nil,
                segments: plan.segments,
                voice: voice,
                radioTreatment: request.radioTreatment,
                onEvent: makeSpeechEventBridge(
                    target: playbackTarget,
                    onPlaybackEvent: onPlaybackEvent
                )
            )
            return .spoken(renderedSegments)
        }
    }
}
```

The actual `PlagueImmersiveCoordinator` call site should be `@MainActor` and should bridge playback events into `GravitasDemoAudioController`. Turing services themselves should not be `@MainActor`.

## 17. Story script authoring shape

Keep episode commands compact, but compile them into typed runtime nodes.

Example script:

```json
[
  {
    "voiceScript": {
      "id": "prologue.radio.001",
      "speaker": "radio_host",
      "voiceID": "radio_host_clone_v1",
      "emotion": "urgent",
      "text": "If you can hear this, keep the radio close. The walls are listening now.",
      "target": {
        "kind": "prop",
        "id": "prologue_wall_radio"
      }
    }
  },
  {
    "voicePrompt": {
      "id": "prologue.big_mike.001",
      "speaker": "big_mike",
      "voiceID": "big_mike_clone_v1",
      "emotion": "low_warning",
      "intent": "Warn the player not to trust the broadcast, in one short turn.",
      "target": {
        "kind": "character",
        "id": "big_mike",
        "anchor": "head"
      }
    }
  }
]
```

Compiler responsibilities:

- assign stable runtime node IDs
- validate required fields
- validate voice IDs
- validate character profile IDs
- validate Bible IDs
- validate prop targets
- register gaze targets
- register wall occupancy for story radio props
- route voice actions to `TuringCoordinator`
- keep runtime routing out of Foundation Models prompts

## 18. Wall radio prop integration

Use the existing wall placement pattern:

1. Add `.storyRadio` or use `.other` with a clear label in `WallPropOccupancyKind`.
2. Use `WallPlaneManager` to choose a wall.
3. Use `WallPropOccupancyRegistry` to avoid overlap with poster and portals.
4. Follow `WallMountedPosterUIController.placeOnBestWall` style for committed placement.
5. Add a prop root entity with a child audio emitter entity.
6. Register a gaze/input component on the prop, not on the HUD.
7. Route prop activation to `TuringPropInteractionController`.
8. Route final playback to `TuringSpatialAudioAdapter`.

Suggested additions:

```swift
enum TuringPropKind: String, Codable, Sendable {
    case wallRadio
    case characterAnchor
}

struct TuringPropRuntimeRecord: Sendable {
    let id: String
    let kind: TuringPropKind
    let rootEntityName: String
    let audioEmitterName: String
    let playbackTarget: TuringPlaybackTarget
}
```

If `WallPropOccupancyKind` is edited, add:

```swift
case storyRadio
```

Then update hard-overlap rules so story radios cannot overlap posters, portals, or other story radios.

## 19. Dictation and HUD behavior

MVP rule:

- Player dictated words may appear in `PlagueHeadTrackedInstructionHUD`.
- Qwen character speech must not be shown as subtitles.

Dictation flow:

1. Player activates radio / character prompt.
2. `TuringDictationCoordinator` starts speech recognition.
3. HUD displays partial/final player words.
4. Final player text is passed to `conversationPrompt`.
5. HUD clears or returns to instruction state.
6. Character response plays spatially only.

## 20. Error handling

Define user-visible errors. Do not hide them with fake dialogue.

```swift
enum TuringRuntimeError: LocalizedError {
    case foundationUnavailable
    case foundationJSONGateFailed(String)
    case foundationRepairFailed(String)
    case qwenGPUUnavailable
    case qwenModelLoadFailed(String)
    case qwenSynthesisFailed(String)
    case audioCacheFailed(String)
    case playbackFailed(String)
    case bibleUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .foundationUnavailable:
            return "Foundation Models are unavailable."
        case .foundationJSONGateFailed(let detail):
            return "Foundation Models returned invalid JSON: \(detail)"
        case .foundationRepairFailed(let detail):
            return "Foundation Models JSON repair failed: \(detail)"
        case .qwenGPUUnavailable:
            return "Qwen TTS requires Apple GPU execution and it is unavailable."
        case .qwenModelLoadFailed(let detail):
            return "Qwen model load failed: \(detail)"
        case .qwenSynthesisFailed(let detail):
            return "Qwen synthesis failed: \(detail)"
        case .audioCacheFailed(let detail):
            return "Turing audio cache failed: \(detail)"
        case .playbackFailed(let detail):
            return "Turing playback failed: \(detail)"
        case .bibleUnavailable(let bibleID):
            return "Bible source unavailable: \(bibleID)"
        }
    }
}
```

If product wants spoken error recovery, it must be its own `voicePrompt` or `conversationPrompt` action. It still goes through Foundation Models, JSON gate, Qwen, and cache. No code-authored apology.

## 21. Cancellation and memory cleanup

Cancellation rules:

- Cancelling an action cancels outstanding Foundation Models chunk tasks.
- Cancelling an action cancels segment renders that have not started playback.
- Do not cancel the active segment render unless the user exits, changes playback target, or cancels the audiobook/story action.
- Qwen session cleanup must run on cancellation.
- Cache temp files must be removed if the render did not complete.

Qwen per-segment lifecycle:

1. Confirm GPU.
2. Load shared model weights if needed.
3. Create fresh session.
4. Synthesize one segment.
5. Write audio file.
6. Store metadata.
7. Release request-local session state.
8. Clear temporary MLX arrays where supported.

## 22. Soak tests and acceptance tests

Mandatory tests before story use:

### 22.1 No deterministic fallback tests

- Foundation response malformed, repair malformed: action fails.
- Segmentation response missing text: action fails.
- Focus chunk response empty: action fails.
- No code path creates replacement speech.
- No system TTS path exists.

### 22.2 Exact segmentation tests

- Concatenated segments exactly equal normalized input.
- Segment indexes are stable and ordered.
- Empty input fails.
- Markdown-fenced valid JSON is accepted after wrapper cleanup.
- JSON with extra prose but one balanced object is accepted.
- JSON needing invented fields is rejected and sent to repair.

### 22.3 Focus parallelism tests

- 10 chunk jobs with limiter 4 never exceed 4 concurrent Foundation Models calls.
- High priority waiters run before normal priority waiters.
- Results sort back into chunk index order.
- Reduction repeats until aggregate fits.
- Cancellation drains task group without leaving active permits.

### 22.4 TTS scheduler tests

- Renders one segment at a time.
- Cache hit skips Qwen session creation.
- Cache key changes when model revision changes.
- Cache key changes when voice revision changes.
- Cache key changes when emotion changes.
- GPU unavailable fails loudly.

### 22.5 Sequential segment compute-ahead tests

- Segments render one at a time.
- First segment playback event fires as soon as the first segment is ready.
- Later segments enqueue in returned order.
- Foundation can prepare the next audiobook source section while Qwen renders or playback speaks the current section.
- No packet object is created.
- No split-in-half behavior exists.

### 22.6 Qwen lifecycle soak test

Run on device:

1. Load Qwen host once.
2. Record baseline memory.
3. Generate 20 unique short segments.
4. Use a fresh synthesis session for each segment.
5. Persist every audio file.
6. Release request-local state after every segment.
7. Record memory after every segment.
8. Cancel one render mid-flight and confirm cleanup.
9. Force one malformed voice request and confirm no session leak.

Pass criteria:

- No sustained upward memory slope after transient warmup.
- Cancelled sessions release transient state.
- Failed sessions release transient state.
- Cached playback does not instantiate synthesis sessions.

## 23. Implementation phases

### Phase 0: scaffolding and gates

- Add Turing folder structure.
- Add config decoders.
- Add prompt template store.
- Add JSON sanitizer, gates, and repair service.
- Add strict tests for no deterministic fallback.
- Add the Story Mode unlock flags, Prologue episode catalog, and SwiftUI episode picker described in Section 25.
- Route early Turing test actions through Story Mode / Prologue only. Do not attach new Turing test buttons to Horde.

### Phase 1: exact `voiceScript`

- Implement exact segmentation prompt.
- Implement speech pipeline with a test TTS backend injected only in tests.
- Implement first-segment-ready playback behavior.
- MainActor adapter logs playback events before real Qwen is ready.

Test backend rule:

The test backend is for unit tests only and must not be compiled into production as a fallback.

### Phase 2: Qwen MLX host

- Add model registry.
- Add Qwen model loader.
- Enforce GPU requirement.
- Add sequential scheduler.
- Add audio file writer and cache.
- Run Qwen lifecycle soak test.

### Phase 3: Plague spatial playback

- Add `TuringSpatialAudioAdapter`.
- Add `GravitasDemoAudioController` entry point for Turing cache files.
- Add wall radio emitter or character head emitter routing.
- Start playback on the first rendered segment and enqueue later segments sequentially.

### Phase 4: `voicePrompt` and `conversationPrompt`

- Add character profile store.
- Add prompt templates.
- Add dictation coordinator.
- Keep HUD player-only.
- Gate and repair all dialogue plans.

### Phase 5: Bible Focus

- Add Bible catalog.
- Add Bible source loader.
- Add chunked Focus summary service.
- Add parallel reducer.
- Add `focusPrompt`.

### Phase 6: story compiler and prop interactions

- Add episode script compiler.
- Add wall radio prop placement.
- Add gaze activation.
- Add story trigger routing.
- Keep Story/Horde separation through `PlagueDemoSession`.
- Make Prologue the first episode/runtime test bed for `voiceScript`, `voicePrompt`, `conversationPrompt`, Focus, prop activation, and spatial playback.
- Keep Horde code present, but allow Horde to be locked by feature flag for distribution.

### Phase 7: device hardening

- Soak Qwen memory.
- Measure Foundation Models concurrency.
- Tune max parallel requests.
- Verify cancellation.
- Verify cache persistence and cleanup.
- Verify no subtitles for Qwen speech.

## 24. Done criteria

Turing MVP is ready when:

- `voiceScript` can speak exact authored text through Qwen spatial audio.
- `voicePrompt` can generate character speech through Foundation Models and speak it through Qwen.
- `conversationPrompt` can respond to player dictation.
- Focus can process long Bible text using bounded parallel Foundation Models chunking.
- First rendered segment begins playback while later segments continue sequential synthesis.
- Cache hits play without Qwen synthesis.
- Qwen GPU requirement is enforced.
- No Python or PyTorch ships.
- No deterministic semantic fallback remains.
- Audiobook malformed JSON paths are sanitize, parse, Foundation Models repair, parse, fail.
- Plague reuses existing wall placement, wall occupancy, HUD, spatial audio, and MainActor coordinator systems.

## 25. Plague repo integration code: Story Mode, Prologue, and unlocks

This section is the repo-specific handoff for wiring Turing into the current Gravitas Plague codebase.

The important product rule is:

```text
All new Turing phases enter through Story Mode.
The first test episode is Prologue.
Horde Mode may be locked by default for distribution later, but Horde code must remain intact.
Do not delete Horde systems to create Story Mode.
```

Current repo entry points:

```text
Gravitas Plague/Gravitas Plague/PlagueDemoSession.swift
  Owns PlagueExperienceMode, PlagueOperationMode, mode selection, command routing,
  window/session state, HUD status, and leaderboard state.

Gravitas Plague/Gravitas Plague/UI/OperationModePosterResources.swift
  Owns operation-mode lock/unlock snapshot used by both SwiftUI and RealityKit poster UI.

Gravitas Plague/Gravitas Plague/PlagueOperationModePosterMenu.swift
  SwiftUI poster menu. This is where Story Mode should open the episode picker.

Gravitas Plague/Gravitas Plague/UI/WallMountedPosterUIController.swift
  RealityKit poster UI. It uses the same OperationModeAccessController snapshot.

Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift
  MainActor application shell for RealityKit, spatial audio attachment, HUD, room scan,
  wall props, portals, Horde, and Story/Turing command application.

Gravitas Plague/Gravitas Plague/GravitasDemoAudioController.swift
  Existing spatial audio owner. Turing must add an entry point here instead of creating
  a separate audio system.
```

### 25.1 Story/Horde feature flags

Patch `PlagueFeatureFlags` in `PlagueDemoSession.swift`.

The goal is not to hard-delete Horde. The goal is to make the build decide which modes are visible/unlocked.

```swift
enum PlagueFeatureFlags {
    static let showStoryRoomSkinningControls = false
    static let showForestDayNightToggle = false
    static let showDebugTestDoor = false

    /// Development: true so Story Mode can host Turing/Prologue work.
    /// Distribution can keep this true once Story is ready.
    static let unlockStoryMode = true

    /// Development: true while Horde remains a test target.
    /// Distribution can set this false without deleting Horde code.
    static let unlockHordeMode = true

    /// Story button opens an episode picker instead of directly starting gameplay.
    static let showStoryEpisodePicker = true

    /// First active Turing test episode.
    static let defaultStoryEpisodeID = TuringEpisodeID.prologue
}
```

### 25.2 Operation mode locks

Patch `OperationModePosterResources.swift`.

Existing code has:

```swift
enum OperationModeLockReason: String, Sendable {
    case storyLockedForCurrentBuild
}
```

Replace with:

```swift
enum OperationModeLockReason: String, Sendable {
    case storyLockedForCurrentBuild
    case hordeLockedForDistribution
}
```

Existing code has:

```swift
@Published private(set) var snapshot = OperationModeAccessSnapshot(
    story: .locked(.storyLockedForCurrentBuild),
    horde: .unlocked
)
```

Replace the default and `refresh()` with feature-flag-driven access:

```swift
@Published private(set) var snapshot = OperationModeAccessController.makeSnapshot()

private static func makeSnapshot() -> OperationModeAccessSnapshot {
    OperationModeAccessSnapshot(
        story: PlagueFeatureFlags.unlockStoryMode
            ? .unlocked
            : .locked(.storyLockedForCurrentBuild),
        horde: PlagueFeatureFlags.unlockHordeMode
            ? .unlocked
            : .locked(.hordeLockedForDistribution)
    )
}

func refresh() {
    snapshot = Self.makeSnapshot()
}
```

This keeps the existing poster lock overlays working in both SwiftUI and RealityKit because both paths read the same `OperationModeAccessController.shared.snapshot`.

### 25.3 Episode catalog

Add:

```text
Gravitas Plague/Gravitas Plague/Turing/Story/TuringEpisodeCatalog.swift
```

```swift
import Foundation

enum TuringEpisodeID: String, Codable, CaseIterable, Identifiable, Sendable {
    case prologue

    var id: String { rawValue }
}

struct TuringEpisodeDescriptor: Identifiable, Sendable, Equatable {
    let id: TuringEpisodeID
    let title: String
    let subtitle: String
    let scriptResourcePath: String
    let isUnlocked: Bool
}

enum TuringEpisodeCatalog {
    static let developmentEpisodes: [TuringEpisodeDescriptor] = [
        TuringEpisodeDescriptor(
            id: .prologue,
            title: "Prologue",
            subtitle: "Turing system test bed",
            scriptResourcePath: "Turing/Scripts/Prologue/prologue.json",
            isUnlocked: true
        )
    ]

    static func descriptor(
        for id: TuringEpisodeID
    ) -> TuringEpisodeDescriptor? {
        developmentEpisodes.first { $0.id == id }
    }
}
```

Resource shape:

```text
Gravitas Plague/Gravitas Plague/Resources/Turing/Scripts/Prologue/prologue.json
Gravitas Plague/Gravitas Plague/Resources/Turing/Scripts/Prologue/voiceScripts.json
Gravitas Plague/Gravitas Plague/Resources/Turing/Bibles/Prologue/catalog.json
```

MVP `prologue.json` should contain at least one command for each Turing path as those phases come online:

```json
[
  {
    "voiceScript": {
      "id": "prologue.radio.001",
      "speaker": "radio_host",
      "voiceID": "radio_host_clone_v1",
      "emotion": "urgent",
      "text": "If you can hear this, keep the radio close. The walls are listening now.",
      "target": {
        "kind": "prop",
        "id": "prologue_wall_radio"
      }
    }
  }
]
```

### 25.4 Session state and Story command

Patch `PlagueDemoSession.swift`.

Add a Story command case:

```swift
enum Command: Equatable {
    case startJockRetargetTest
    case playJockPacingLoop
    case playJockFollowDemo
    case stopJockFollowDemo
    case playJockClip(String, loop: Bool)
    case updateForestAtmosphere(PlagueForestAtmosphere)
    case startHordeRoomScanOnly
    case startStoryEpisode(TuringEpisodeID)
}
```

Add published Story state:

```swift
@Published var storyEpisodePickerPresented = false
@Published var selectedStoryEpisodeID: TuringEpisodeID?
@Published private(set) var availableStoryEpisodes =
    TuringEpisodeCatalog.developmentEpisodes
```

Patch `selectOperationMode(_:)` for `.story`.

Replace:

```swift
case .story:
    experienceMode = .story
    statusMessage = "Story Mode is locked for this build."
```

With:

```swift
case .story:
    experienceMode = .story
    selectedOperationMode = .story

    if PlagueFeatureFlags.showStoryEpisodePicker {
        storyEpisodePickerPresented = true
        statusMessage = "Choose an episode."
    } else {
        startStoryEpisode(
            PlagueFeatureFlags.defaultStoryEpisodeID
        )
    }
```

Add:

```swift
@MainActor
func startStoryEpisode(
    _ episodeID: TuringEpisodeID
) {
    guard let descriptor = TuringEpisodeCatalog.descriptor(
        for: episodeID
    ), descriptor.isUnlocked else {
        statusMessage = "Episode is locked for this build."
        return
    }

    experienceMode = .story
    selectedOperationMode = .story
    selectedStoryEpisodeID = episodeID
    storyEpisodePickerPresented = false
    statusMessage = "Starting \(descriptor.title)."

    send(
        .startStoryEpisode(episodeID)
    )

    print(
        """
        [StoryMode] episode selected
          episodeID: \(episodeID.rawValue)
          title: \(descriptor.title)
          script: \(descriptor.scriptResourcePath)
        """
    )
}
```

Reset paths that currently clear mode state should also clear Story UI state:

```swift
storyEpisodePickerPresented = false
selectedStoryEpisodeID = nil
```

Do not clear `availableStoryEpisodes` unless the catalog is being reloaded.

### 25.5 SwiftUI episode picker

Patch `PlagueOperationModePosterMenu.swift`.

Attach a sheet to the top-level view in `PlagueOperationModePosterMenu.body`:

```swift
.sheet(
    isPresented: $session.storyEpisodePickerPresented
) {
    TuringEpisodePickerView(
        session: session
    )
}
```

Add the SwiftUI picker in the same file initially, or move it to:

```text
Gravitas Plague/Gravitas Plague/Turing/Story/TuringEpisodePickerView.swift
```

```swift
import SwiftUI

struct TuringEpisodePickerView: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Story Episodes")
                .font(.title2.weight(.semibold))

            ForEach(session.availableStoryEpisodes) { episode in
                Button {
                    session.startStoryEpisode(episode.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.title)
                                .font(.headline)

                            Text(episode.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if episode.isUnlocked {
                            Image(systemName: "chevron.right")
                        } else {
                            Image(systemName: "lock.fill")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!episode.isUnlocked)
            }

            Button("Cancel") {
                session.storyEpisodePickerPresented = false
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 420)
    }
}
```

This picker is intentionally SwiftUI. It is not a RealityKit wall poster replacement. Story Mode uses this to choose Prologue while the Turing runtime is being built.

### 25.6 Immersive coordinator Story command routing

Patch `PlagueImmersiveCoordinator.handle(_:)` or the existing command switch where `PlagueDemoSession.Command` is applied.

Add:

```swift
case .startStoryEpisode(let episodeID):
    startStoryEpisode(
        episodeID
    )
```

Add a MainActor Story starter:

```swift
@MainActor
private func startStoryEpisode(
    _ episodeID: TuringEpisodeID
) {
    guard let descriptor = TuringEpisodeCatalog.descriptor(
        for: episodeID
    ) else {
        instructionHUD.show(
            "Missing episode: \(episodeID.rawValue)",
            on: headAnchor
        )
        return
    }

    stopHordeBenchmark()
    clearArchitectureSnapshots()

    print(
        """
        [StoryMode] starting episode
          episodeID: \(episodeID.rawValue)
          title: \(descriptor.title)
          script: \(descriptor.scriptResourcePath)
          route: Turing
        """
    )

    Task { [weak self] in
        do {
            try await self?.runTuringEpisode(
                descriptor
            )
        } catch {
            await MainActor.run {
                self?.instructionHUD.show(
                    "Story error: \(error.localizedDescription)",
                    on: self?.headAnchor
                )
            }
        }
    }
}
```

The call to `stopHordeBenchmark()` is deliberate. Story and Horde must not run concurrently. This does not delete Horde; it only stops active Horde runtime before Story starts.

Add a placeholder until the script runtime exists:

```swift
private func runTuringEpisode(
    _ descriptor: TuringEpisodeDescriptor
) async throws {
    // Phase 0 placeholder:
    // - load descriptor.scriptResourcePath
    // - compile EpisodeRuntimeNode values
    // - route each node into TuringCoordinator
    // - route playback events back to MainActor spatial audio
    print(
        """
        [Turing] episode runtime placeholder
          episodeID: \(descriptor.id.rawValue)
          script: \(descriptor.scriptResourcePath)
        """
    )
}
```

When `TuringScriptRuntime` exists, replace the placeholder with:

```swift
private let turingCoordinator = TuringCoordinator(...)
private var activeTuringRuntime: TuringScriptRuntime?

private func runTuringEpisode(
    _ descriptor: TuringEpisodeDescriptor
) async throws {
    let runtime = try await TuringScriptRuntime.load(
        descriptor: descriptor,
        coordinator: turingCoordinator
    )

    await MainActor.run {
        activeTuringRuntime = runtime
    }

    try await runtime.start(
        playbackEventHandler: { [weak self] event in
            await self?.applyTuringPlaybackEvent(event)
        }
    )
}
```

### 25.7 Spatial audio adapter into existing audio controller

Turing must not create a parallel spatial audio system. Add an entry point to `GravitasDemoAudioController`.

Suggested shape:

```swift
extension GravitasDemoAudioController {
    @MainActor
    func playTuringRenderedSegment(
        id: String,
        fileURL: URL,
        target: TuringPlaybackTarget,
        sceneRoot: Entity?,
        propRecords: [String: TuringPropRuntimeRecord],
        characterControllersByID: [String: JockRetargetTestController]
    ) throws {
        let emitter = try resolveTuringEmitter(
            target: target,
            sceneRoot: sceneRoot,
            propRecords: propRecords,
            characterControllersByID: characterControllersByID
        )

        try playSpatialAudioFile(
            id: id,
            fileURL: fileURL,
            emitter: emitter
        )
    }
}
```

If the current audio controller does not have `playSpatialAudioFile`, add the smallest internal method that mirrors the existing audio-resource + playback-controller pattern. Do not duplicate the whole audio stack.

MainActor adapter in `PlagueImmersiveCoordinator`:

```swift
@MainActor
private func applyTuringPlaybackEvent(
    _ event: TuringPlaybackEvent
) {
    switch event {
    case .segmentReady(let segment, let target):
        do {
            try audioController.playTuringRenderedSegment(
                id: "turing.\(segment.cacheKey)",
                fileURL: segment.fileURL,
                target: target,
                sceneRoot: sceneRoot,
                propRecords: turingPropRecordsByID,
                characterControllersByID: turingCharacterControllersByID
            )
        } catch {
            instructionHUD.show(
                "Turing playback failed: \(error.localizedDescription)",
                on: headAnchor
            )
        }
    }
}
```

### 25.8 Prologue test harness

All early tests should be reachable by selecting:

```text
Story Mode -> Prologue
```

Do not add more Horde buttons for Turing test phases.

Add:

```text
Gravitas Plague/Gravitas Plague/Turing/Debug/TuringPrologueTestHarness.swift
```

```swift
enum TuringPrologueTestHarness {
    static func phase0Script() -> [EpisodeScriptCommand] {
        [
            .voiceScript(
                VoiceScriptRequest(
                    id: "prologue.test.voiceScript.001",
                    voiceID: "radio_host_clone_v1",
                    emotion: "urgent",
                    text: "If you can hear this, keep the radio close.",
                    radioTreatment: .handheldRadio
                )
            )
        ]
    }

    static func phaseNamesAvailableForPrologue() -> [String] {
        [
            "voiceScript exact segmentation",
            "Qwen sequential synthesis",
            "spatial radio playback",
            "voicePrompt character intent",
            "conversationPrompt dictation",
            "Bible Focus"
        ]
    }
}
```

The harness is a script/runtime input generator only. It must not produce code-authored replacement dialogue at runtime.

### 25.9 Story/Horde behavior matrix

| Build mode | Story button | Horde button | Walk Loop |
|---|---:|---:|---:|
| Turing development | unlocked | unlocked | unlocked |
| Story QA | unlocked | locked by `unlockHordeMode = false` | unlocked |
| Horde QA | locked by `unlockStoryMode = false` | unlocked | unlocked |
| Distribution, Story-first | unlocked | locked by `unlockHordeMode = false` | optional |

Implementation rule:

```text
Locking means access snapshot says locked.
Locking does not mean deleting code, removing assets, or changing Horde runtime internals.
```

### 25.10 Acceptance for Story shell

Before implementing Qwen or Foundation Models, the shell is correct when:

- Story Mode can be unlocked by `PlagueFeatureFlags.unlockStoryMode`.
- Horde Mode can be locked by `PlagueFeatureFlags.unlockHordeMode = false` without deleting Horde code.
- Clicking Story Mode opens a SwiftUI episode picker.
- The picker lists Prologue.
- Selecting Prologue sends `.startStoryEpisode(.prologue)`.
- `PlagueImmersiveCoordinator` receives that command and logs `[StoryMode] starting episode`.
- Story start stops active Horde runtime if Horde was running.
- No Turing testing entry point is added to Horde Mode.
- The existing player dictation HUD remains player-only.
- Qwen character speech is routed through the existing spatial audio controller when implemented.
