# Gravitas Plague - Production Script Voice / Prompt Voice Pipeline

## Architect implementation handoff

**Repository:** `/Users/richardfallat/Projects/dev/gravitas-plague`

**Immediate target:** `prologue.scriptPoint05`

**Long-term target:** Any Turing Flow script point containing an authored long-form
`scriptVoice` stage followed by a generated `promptVoice` stage.

This document is self-contained. It records the working audiobook-demo path, the
current ScriptPoint05 implementation, the device failure, and the production
architecture required to make this behavior reproducible.

---

# 1. Product behavior

ScriptPoint04 and ScriptPoint05 must run as one authored progression:

```text
ScriptPoint04 PR
-> ScriptPoint04 promptVoice generation and playback
-> ScriptPoint04 send comm
-> automatically start ScriptPoint05
-> begin ScriptPoint05 scriptVoice preparation
-> run ten seconds of walkie send static/filler
-> play ScriptPoint05 PR
-> continue scriptVoice preparation while the PR plays
-> render and play the authored headline as scriptVoice
-> render and play the generated personal follow-up as promptVoice
-> return the microphone interaction state
```

The authored headline is not a promptVoice response. It is exact source material
that Foundation splits into TTS-sized pieces and Qwen reads in Big Mike's clone.

The personal follow-up is a separate promptVoice stage. Its Foundation failure
must never erase, cancel, or prevent playback of an already accepted scriptVoice
stage.

---

# 2. The device log proves the current defect

The failing device run did not fail audiobook input preparation. It successfully
prepared the scriptVoice text:

```text
[TuringPhase1Audiobook] source normalized
  requestID: prologue.scriptPoint05.headlineReading
  normalizedUTF16: 781

[TuringPhase1Audiobook] source sections planned
  sectionCount: 1
  targetWords: 120
  minWords: 45
  maxWords: 210
  maxChars: 2400

[TuringFoundation] audiobook section segmentation accepted
  sectionIndex: 0
  segmentCount: 11

[TuringFlowComposite] scriptVoice audiobook plan finished
  scriptPointID: prologue.scriptPoint05
  stageID: headlineReading
  sectionCount: 1
  segmentCount: 11
```

No Qwen request was submitted for those 11 segments. Instead, the composite
planner immediately started the dependent promptVoice Foundation request:

```text
[TuringVoicePrompt] Foundation request started
  id: prologue.bigMike.scriptPoint05.followUp.001

[TuringFoundationFreshSession] response failed
  purpose: voicePrompt_characterIntent
  error: The model's safety guardrails were triggered.

[TuringPlaybackRebuild] expected generated count set
  expectedSegmentCount: 0

[TuringFlow] point failed
  stage: generatedPlanFailed
```

The accepted audiobook segments were lost because ScriptPoint05 currently has an
all-or-nothing composite plan. This is an execution-architecture defect, not an
audiobook segmentation defect.

---

# 3. Working audiobook demo call chain

The production implementation must preserve the behavior established by the
debug audiobook demo.

```text
TuringEpisodePickerView
  ATNV-15 Cases Spread Across City

-> TuringNativeQwenHelloWorldCanary
-> load long input text
-> TuringVoiceScriptLongformRunner.makeSourcePlan
-> TuringPhase1AudiobookRunner.makeSourcePlan
-> TuringAudiobookSourceNormalizer.normalize
-> TuringAudiobookSourceSectioner.makeSections

for each section in source order:
  -> TuringVoiceScriptLongformRunner.prepareSection
  -> TuringPhase1AudiobookRunner.prepareSection
  -> fresh Foundation LanguageModelSession
  -> voiceScript_audiobookSourceSectionSegmentation.txt
  -> sanitize/decode sparse JSON
  -> one fresh-session malformed-JSON repair if needed
  -> accepted TuringAudiobookSpeechSegment values
  -> exact spokenText values become Qwen requests immediately
  -> Fresh2 render/decode
  -> publish decoded segment to ordered playback immediately

after the final source section:
  -> seal generated input
  -> wait for actual playback completion callbacks
  -> unload Fresh2
```

Relevant existing files:

```text
Gravitas Plague/Gravitas Plague/Turing/Story/TuringEpisodePickerView.swift
Gravitas Plague/Gravitas Plague/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift
Gravitas Plague/Gravitas Plague/Turing/Speech/TuringVoiceScriptLongformRunner.swift
Gravitas Plague/Gravitas Plague/Turing/Speech/TuringPhase1AudiobookRunner.swift
Gravitas Plague/Gravitas Plague/Turing/Speech/TuringAudiobookSourceNormalizer.swift
Gravitas Plague/Gravitas Plague/Turing/Speech/TuringAudiobookSourceSectioner.swift
Gravitas Plague/Gravitas Plague/Turing/Speech/TuringAudiobookSourceSectionPolicy.swift
Gravitas Plague/Gravitas Plague/Turing/Speech/TuringAudiobookSegmentationParser.swift
Gravitas Plague/TuringResources/Turing/Prompts/voiceScript_audiobookSourceSectionSegmentation.txt
```

The critical working-demo boundary is this existing structure from
`TuringNativeQwenHelloWorldCanary.runAudiobookSections`:

```swift
currentTask = makeSectionTask(0)

while let task = currentTask {
    let nextSectionIndex = currentSectionIndex + 1
    nextTask = makeSectionTask(nextSectionIndex)
    let sectionResult = try await task.value

    let sectionTexts = sectionResult.segments.map(\.spokenText)
    let requests = makeParallelBaseCloneRequests(
        preset: preset,
        cloneProfile: cloneProfile,
        segments: sectionTexts,
        startingSegmentIndex: renderedSegmentCount
    )

    try await renderFreshBaseCloneRequests(
        requests,
        scheduler: scheduler,
        gapAudio: gapAudio,
        runID: "\(runID).section\(sectionResult.section.index)",
        modelRoot: stagedRoot,
        skipQwenSegmentFailures: true
    )

    renderedSegmentCount += sectionTexts.count
    currentSectionIndex = nextSectionIndex
    currentTask = nextTask
    nextTask = nil
}
```

The accepted section is rendered before the pipeline advances. The next section's
Foundation work can prepare concurrently, and decoded audio can play concurrently,
but no later Foundation stage owns or invalidates the accepted section.

---

# 4. Exact source-text preparation

## 4.1 Source resource

ScriptPoint05 reads:

```text
Gravitas Plague/TuringResources/Turing/Scripts/Prologue/
prologue.scriptPoint05.bigMike.voiceScript.txt
```

Current authored source:

```text
Rich, listen to this shit.

THE GRAVITAS PLAGUE SPREADS

Officials are warning residents to stay indoors after new cases of the Gravitas Plague were confirmed across the city.

Doctors say the illness attacks the brain’s fear response. Early victims may seem confused, sleepless, or strangely calm. Later symptoms include cloudy eyes, broken speech, fixation on movement, and sudden agitation.

One hospital worker said, “They look awake, but unreachable.”

The infected are not dead. They are living hosts with severe brain damage.

Residents are advised to lock doors, avoid contact with rabid animals, and report any bite or fluid exposure immediately.

If someone you know appears infected, do not open the door.

If the eyes cloud, isolate.

If speech fails, do not negotiate.
```

This text matches the existing ATNV-15 debug headline input. It is the speech
source, not additional Story context and not dialogue history.

## 4.2 Normalization

Use the existing normalizer without a ScriptPoint-specific rewrite:

```swift
enum TuringAudiobookSourceNormalizer {
    static func normalize(_ raw: String) -> String {
        let lf = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let collapsedNewlines = lf.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        let rawBlocks = collapsedNewlines.components(separatedBy: "\n\n")
        let normalizedBlocks = rawBlocks.compactMap { block -> String? in
            let collapsedSpaces = block.replacingOccurrences(
                of: "[ \t]+",
                with: " ",
                options: .regularExpression
            )
            let trimmed = collapsedSpaces.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        }

        return normalizedBlocks.joined(separator: "\n\n")
    }
}
```

Normalization is deterministic and local. Foundation does not rewrite the source
before sectioning.

## 4.3 Source sections

Use the established section policy:

```swift
struct TuringAudiobookSourceSectionPolicy: Sendable, Equatable {
    let targetWords: Int = 120
    let minWords: Int = 45
    let maxWords: Int = 210
    let maxChars: Int = 2400
}
```

The sectioner:

```text
1. Preserves paragraph order.
2. Uses non-overlapping UTF-16 source ranges.
3. Keeps ordinary paragraphs as units.
4. Splits oversized paragraphs into sentence units.
5. Starts a new section at the target/max word or character boundary.
6. Never serializes duplicate previous/next source text into the prompt.
```

The current ScriptPoint05 source is 122 words and becomes one section.

---

# 5. How Foundation prepares scriptVoice

For every source section, call
`TuringPhase1AudiobookRunner.prepareSection`.

It renders this existing prompt resource:

```text
You are a speech segmentation planner for a story-mode audiobook text-to-speech pipeline.

Task:
Split the source section into natural spoken TTS segments.

Prompt responsibilities:
- Cover the full section.
- Preserve order.
- Target 3 to 5 seconds per spoken segment.
- Avoid tiny segments.
- Split long sentences naturally.
- Return JSON only. No markdown. No prose outside JSON.
- Return segments only for the source section text.

Return this exact sparse JSON schema:
{
  "schemaVersion": 1,
  "sectionIndex": {{sectionIndex}},
  "segments": [
    {
      "index": 0,
      "spokenText": "string sent to TTS",
      "emotion": "narration"
    }
  ]
}

Source section text to segment:
"""
{{sectionText}}
"""
```

Foundation lifecycle:

```text
render one section prompt
-> create a fresh LanguageModelSession
-> submit exactly one prompt
-> session returns or throws
-> session scope ends
-> sanitize one top-level JSON object
-> decode TuringAudiobookSegmentationPayload
-> map response order to local indexes
-> apply default emotion when empty
```

Malformed JSON receives the existing single repair request through another fresh
session. Do not retain Foundation sessions. Do not add continuation history,
checkpoint state, room state, or previous generated turns.

The accepted payload type remains:

```swift
struct TuringAudiobookSegmentationPayload: Codable, Sendable {
    let schemaVersion: Int?
    let sectionIndex: Int?
    let segments: [Segment]

    struct Segment: Codable, Sendable {
        let index: Int?
        let spokenText: String
        let emotion: String?
    }
}
```

The exact `spokenText` returned for each accepted segment becomes the exact Qwen
input. No second LLM rewrites scriptVoice text.

The failing device run returned and accepted these 11 segments:

```text
0  Rich, listen to this shit.
1  THE GRAVITAS PLAGUE SPREADS
2  Officials are warning residents to stay indoors after new cases of the Gravitas Plague were confirmed across the city.
3  Doctors say the illness attacks the brain’s fear response. Early victims may seem confused, sleepless, or strangely calm.
4  Later symptoms include cloudy eyes, broken speech, fixation on movement, and sudden agitation.
5  One hospital worker said, “They look awake, but unreachable.”
6  The infected are not dead. They are living hosts with severe brain damage.
7  Residents are advised to lock doors, avoid contact with rabid animals, and report any bite or fluid exposure immediately.
8  If someone you know appears infected, do not open the door.
9  If the eyes cloud, isolate.
10 If speech fails, do not negotiate.
```

Those strings were valid scriptVoice inputs. The production defect occurred after
their acceptance.

---

# 6. What ScriptPoint05 currently implements

Current descriptor behavior is correct and should remain:

```json
{
  "scriptPointID": "prologue.scriptPoint05",
  "trigger": {
    "kind": "priorScriptPointCompleted",
    "delaySeconds": 0
  },
  "transmission": {
    "characterID": "big_mike",
    "outputRoute": "walkieSpatial",
    "computeStart": "beforePrerecording",
    "fillerMode": "continuousFromPrerecordingToGenerated",
    "fixedLeadInSeconds": 10,
    "generationPipeline": {
      "schemaVersion": 1,
      "radioBridgeMode": "bigMikeStaticAndFiller",
      "stages": [
        {
          "stageID": "headlineReading",
          "kind": "voiceScriptLongform",
          "sourceResourcePath": "Turing/Scripts/Prologue/prologue.scriptPoint05.bigMike.voiceScript.txt",
          "voicePromptID": null,
          "defaultEmotion": "measured, official, uneasy, reading carefully",
          "contextSource": {
            "kind": "prerecordingTranscript",
            "stageID": null
          }
        },
        {
          "stageID": "personalFollowUp",
          "kind": "voicePrompt",
          "sourceResourcePath": null,
          "voicePromptID": "prologue.bigMike.scriptPoint05.followUp.001",
          "defaultEmotion": "controlled, uneasy, protective, trying to sound casual",
          "contextSource": {
            "kind": "stageSourceTranscript",
            "stageID": "headlineReading"
          }
        }
      ]
    }
  }
}
```

Current ScriptPoint04 behavior is also correct and should remain:

```json
{
  "progression": {
    "nextScriptPointID": "prologue.scriptPoint05",
    "automaticAdvance": true,
    "interactionGateAfterCompletion": "microphone"
  }
}
```

Automatic advance suppresses ScriptPoint04's temporary microphone gate, plays the
existing send comm, and starts ScriptPoint05. ScriptPoint05 planning starts before
the ten-second lead-in. `runFixedResponseLeadInAfterExternalSend` owns ambient
walkie static, sending static, and the existing comm-filler cadence.

The current implementation shortcut is in
`TuringFlowCompositeSpeechPlanner.build`:

```swift
let resolvedLongform = try await longformRunner.audiobookPlan(...)

let resolvedPrompt = try await voicePromptGenerator.generateVoicePrompt(...)

let scriptSegments = resolvedLongform.flattenedSegments.map {
    TuringSpeechSegment(text: $0.spokenText, emotion: $0.emotion)
}

let segments = scriptSegments + resolvedPrompt.segments
return TuringFlowCompositeSpeechPlan(
    segments: segments,
    conversationSeed: resolvedPrompt.conversationSeed,
    promptVoiceSeed: promptVoiceSeed
)
```

This code only prepares text. It does not render or publish scriptVoice. The
return value is withheld until promptVoice Foundation succeeds.

`TuringFlowEngine` then waits on that one value:

```swift
plan = try await planTask.value

await createdPlayback.setExpectedGeneratedSegmentCount(
    plan.segments.count
)

renderReport = try await renderer.render(
    segments: plan.segments,
    runID: identity.playbackRunID,
    onStarted: ...,
    onFinished: ...,
    onSkipped: ...
)
```

If any composite stage throws, the engine currently does this:

```swift
await createdPlayback.setExpectedGeneratedSegmentCount(0)
await createdPlayback.qwenComputeAllFinished()
```

That is why accepted scriptVoice text never reached Qwen.

The current production renderer also accepts only one fixed array and owns the
entire Fresh2 lifetime for that array:

```swift
func render(
    segments: [TuringSpeechSegment],
    runID: String,
    ...
) async throws -> TuringCharacterRenderReport
```

It warms Fresh2, renders the array, then unloads. It cannot append a later
promptVoice stage using the same global indexes and resident pool.

Tests added so far only prove descriptor wiring and source-resource presence.
They do not prove that a scriptVoice segment reaches Qwen before promptVoice can
fail. That missing integration test allowed this defect.

---

# 7. Required production architecture

Replace the all-or-nothing composite planner with a reusable staged speech run.

```text
TuringFlowEngine
-> TuringStagedSpeechRunCoordinator
   -> TuringVoiceScriptLongformRunner
   -> TuringFlowVoicePromptGenerating
   -> TuringCharacterQwenRenderSession
   -> TuringStoryWalkiePlaybackCoordinator
```

Ownership rules:

```text
TuringStagedSpeechRunCoordinator
  owns stage ordering, global segment ranges, stage failure policy, and sealing

TuringVoiceScriptLongformRunner
  owns normalization, source sections, Foundation segmentation, and JSON repair

TuringCharacterQwenRenderSession
  owns one character's Fresh2 pool for the complete ScriptPoint run

TuringStoryWalkiePlaybackCoordinator
  owns PR/filler/generated ordering and actual playback completion

TuringFlowEngine
  owns the outer ScriptPoint lifecycle and interaction gate
```

Do not put these responsibilities back into a new ScriptPoint05-specific helper.

The coordinator must iterate the descriptor's ordered `stages` array. Remove the
active planner's requirement that there be exactly two stages. ScriptPoint05 is the
first `voiceScriptLongform -> voicePrompt` instance, not a reason to hard-code two
array offsets into the production engine.

Use a stage executor boundary:

```swift
protocol TuringSpeechStageExecuting: Sendable {
    var kind: TuringFlowGenerationPipelineDescriptor.Stage.Kind { get }

    func prepare(
        stage: TuringFlowGenerationPipelineDescriptor.Stage,
        context: TuringSpeechStageContext
    ) -> AsyncThrowingStream<TuringPreparedSpeechBatch, Error>
}

struct TuringPreparedSpeechBatch: Sendable, Equatable {
    let stageID: String
    let batchID: String
    let isFinalBatchForStage: Bool
    let segments: [TuringSpeechSegment]
}
```

`voiceScriptLongform` emits one prepared batch per accepted audiobook source
section. `voicePrompt` emits one prepared batch containing its generated response.
The coordinator assigns global indexes and renders every batch in descriptor order.
Future stage kinds get another executor without another ScriptPoint-specific flow.

## 7.1 Stage contracts

Add production contracts equivalent to:

```swift
struct TuringCommittedSpeechStage: Sendable, Equatable {
    enum Kind: String, Sendable {
        case scriptVoice
        case promptVoice
    }

    let stageID: String
    let kind: Kind
    let globalRange: Range<Int>
    let segments: [TuringSpeechSegment]
}

struct TuringSpeechStageFailure: Sendable, Equatable {
    let stageID: String
    let stageKind: TuringCommittedSpeechStage.Kind
    let reason: String
}

struct TuringStagedSpeechRunReport: Sendable, Equatable {
    let committedStages: [TuringCommittedSpeechStage]
    let failedStages: [TuringSpeechStageFailure]
    let finalExpectedSegmentCount: Int
    let completedPlaybackCount: Int
}
```

`commit` means the stage owns a stable global index range and is no longer
dependent on later Foundation work.

## 7.2 Reusable Fresh2 render session

Refactor `TuringCharacterQwenRenderer` so one session stays resident across all
stages in one ScriptPoint:

```swift
protocol TuringCharacterRenderSession: Sendable {
    func begin() async throws

    func renderStage(
        _ stage: TuringCommittedSpeechStage,
        onStarted: @Sendable @escaping (Int) async -> Void,
        onFinished: @Sendable @escaping (
            Int,
            TuringComputeGapGeneratedAudio
        ) async -> Void,
        onSkipped: @Sendable @escaping (Int, String) async -> Void
    ) async throws -> TuringCharacterRenderReport

    func finish(reason: String) async
    func cancel(reason: String) async
}
```

Production actor shape:

```swift
actor TuringCharacterQwenRenderSession:
    TuringCharacterRenderSession {

    private let runtime: TuringCharacterRuntimeDefinition
    private let runID: String
    private var pool: TuringQwenNativeFreshInstancePool?
    private var scheduler: TuringQwenNativeFreshInstanceScheduler?
    private var profile: TuringQwenNativeCloneProfile?
    private var stagedModel: URL?
    private var started = false

    func begin() async throws {
        // Acquire the existing character-pool arbiter.
        // Load the existing clone profile and staged model.
        // Warm exactly two Fresh instances.
        // Create one scheduler.
        // Do not render and do not unload here.
    }

    func renderStage(
        _ stage: TuringCommittedSpeechStage,
        onStarted: @Sendable @escaping (Int) async -> Void,
        onFinished: @Sendable @escaping (
            Int,
            TuringComputeGapGeneratedAudio
        ) async -> Void,
        onSkipped: @Sendable @escaping (Int, String) async -> Void
    ) async throws -> TuringCharacterRenderReport {
        guard let scheduler,
              let profile,
              let stagedModel else {
            throw TuringRuntimeError.invalidConfig(
                "Render session was not started."
            )
        }

        let requests = zip(stage.globalRange, stage.segments).map {
            globalIndex, segment in
            TuringQwenNativeBaseCloneSegmentRequest(
                segmentIndex: globalIndex,
                text: segment.text,
                language: "english",
                cloneProfile: profile,
                maxNewRows: runtime.qwen.maxNewRows,
                performanceMode: .performance,
                referenceRowLimit: resolvedReferenceRowLimit,
                referenceWindowStrategy: resolvedWindowStrategy,
                samplingPolicy: runtime.qwen.samplingPolicy,
                samplingSeed: TuringQwenNativeSamplingSeed.make(
                    voiceID: runtime.voiceID,
                    runID: runID,
                    segmentIndex: globalIndex
                ),
                generationQualityPolicy:
                    runtime.qwen.generationQualityPolicy
            )
        }

        return try await scheduler.runSegments(
            requests,
            runID: "\(runID).\(stage.stageID)",
            modelRoot: stagedModel,
            skipSegmentFailures: runtime.qwen.skipSegmentFailures,
            onSegmentStarted: { _, index in
                await onStarted(index)
            },
            onSegmentDecoded: { decoded in
                await onFinished(
                    decoded.segmentIndex,
                    TuringComputeGapGeneratedAudio(
                        segmentIndex: decoded.segmentIndex,
                        samples: decoded.audio.samples,
                        sampleRate: Double(decoded.audio.sampleRate),
                        channelCount: 1
                    )
                )
            },
            onSegmentSkipped: { skipped in
                await onSkipped(
                    skipped.segmentIndex,
                    skipped.errorDescription
                )
            }
        ).asCharacterReport(
            expectedIndices: Set(stage.globalRange)
        )
    }

    func finish(reason: String) async {
        await pool?.unloadAll(reason: reason)
        pool = nil
        scheduler = nil
        profile = nil
        stagedModel = nil
        // Release the existing character-pool arbiter exactly once.
    }
}
```

The existing one-array `render` API can remain as a compatibility adapter for
legacy ScriptPoints. It should internally create a session, commit one stage,
render it, and finish. There must be one underlying production implementation.

Fresh2 and decoder constraints remain unchanged:

```text
resident Fresh instances: exactly 2 while the staged run is active
simultaneous Fresh renders: up to 2
simultaneous speech decoders: at most 1
same-segment render/decode overlap: 0
cross-segment render/decode overlap: allowed
decoded segment publication: immediate
playback cursor advance: actual audio completion only
```

## 7.3 Playback must support an open streaming input

The current coordinator already begins with:

```swift
await playback.beginRun(
    runID: identity.playbackRunID,
    expectedSegmentCount: nil
)
```

Keep the run unsealed while stages are being appended. Add an explicit sealing
operation instead of treating a downstream stage failure as zero generated audio:

```swift
func sealGeneratedInput(finalExpectedSegmentCount: Int) async {
    guard runActive else { return }
    expectedSegmentCount = max(0, finalExpectedSegmentCount)
    allComputeFinished = true
    await reconcile(reason: "generatedInputSealed")
}
```

Do not call `qwenComputeAllFinished` after each stage. Call it once, through
`sealGeneratedInput`, after no more stages can append.

Do not call this after a committed stage:

```swift
setExpectedGeneratedSegmentCount(0)
```

If promptVoice fails after scriptVoice has committed 11 segments, seal with 11,
not zero.

## 7.4 Staged runner algorithm

Production pseudocode:

```swift
func runCompositePipeline(
    descriptor: TuringFlowDescriptor,
    pipeline: TuringFlowGenerationPipelineDescriptor,
    character: TuringCharacterRuntimeDefinition,
    prerecording: TuringPrerecordingDescriptor,
    playback: TuringStoryWalkiePlaybackCoordinator,
    identity: TuringFlowIdentity
) async throws -> TuringStagedSpeechRunReport {
    let scriptStageDescriptor = pipeline.stages[0]
    let promptStageDescriptor = pipeline.stages[1]

    let sourceText = try loadAndNormalizeScriptSource(
        scriptStageDescriptor
    )
    let sourcePlan = try longformRunner.makeSourcePlan(
        request: makeLongformRequest(
            descriptor: descriptor,
            stage: scriptStageDescriptor,
            character: character,
            sourceText: sourceText
        )
    )

    let renderSession = rendererFactory.makeSession(
        runtime: character,
        runID: identity.playbackRunID
    )
    try await renderSession.begin()

    var nextGlobalIndex = 0
    var committedStages: [TuringCommittedSpeechStage] = []
    var failedStages: [TuringSpeechStageFailure] = []
    do {
        for section in sourcePlan.sections {
            let sectionResult = try await longformRunner.prepareSection(
                section,
                in: sourcePlan,
                request: longformRequest
            )
            let segments = sectionResult.segments.map {
                TuringSpeechSegment(
                    text: $0.spokenText,
                    emotion: $0.emotion
                )
            }
            let range = nextGlobalIndex..<(nextGlobalIndex + segments.count)
            let committed = TuringCommittedSpeechStage(
                stageID: "\(scriptStageDescriptor.stageID).section\(section.index)",
                kind: .scriptVoice,
                globalRange: range,
                segments: segments
            )
            committedStages.append(committed)
            nextGlobalIndex = range.upperBound

            try await renderSession.renderStage(
                committed,
                onStarted: { index in
                    await playback.qwenComputeStarted(segmentIndex: index)
                },
                onFinished: { index, audio in
                    await playback.qwenComputeFinished(
                        segmentIndex: index,
                        audio: audio
                    )
                },
                onSkipped: { index, reason in
                    await playback.qwenComputeSkipped(
                        segmentIndex: index,
                        reason: reason
                    )
                }
            )
        }

        // Every scriptVoice segment has now completed Qwen render/decode and
        // has been published to the ordered playback owner. Playback may still
        // be active. Only now may promptVoice Foundation begin.
        do {
            let promptPlan = try await makeFreshPromptVoicePlan(
                descriptor: descriptor,
                stage: promptStageDescriptor,
                character: character,
                exactPriorScriptTranscript:
                    sourcePlan.normalizedSourceText
            )
            let range = nextGlobalIndex..<(nextGlobalIndex + promptPlan.segments.count)
            let committed = TuringCommittedSpeechStage(
                stageID: promptStageDescriptor.stageID,
                kind: .promptVoice,
                globalRange: range,
                segments: promptPlan.segments
            )
            committedStages.append(committed)
            nextGlobalIndex = range.upperBound

            try await renderSession.renderStage(
                committed,
                onStarted: playbackStartedCallback,
                onFinished: playbackFinishedCallback,
                onSkipped: playbackSkippedCallback
            )

            await seedStore.updatePromptVoiceSeed(
                promptVoiceSeed,
                for: descriptor.transmission.conversationKey
            )
        } catch {
            failedStages.append(
                TuringSpeechStageFailure(
                    stageID: promptStageDescriptor.stageID,
                    stageKind: .promptVoice,
                    reason: error.localizedDescription
                )
            )
        }

        await playback.sealGeneratedInput(
            finalExpectedSegmentCount: nextGlobalIndex
        )
        await playback.waitUntilPlaybackFinished()
        await renderSession.finish(reason: "stagedSpeechCompleted")

        return TuringStagedSpeechRunReport(
            committedStages: committedStages,
            failedStages: failedStages,
            finalExpectedSegmentCount: nextGlobalIndex,
            completedPlaybackCount:
                await playback.completedGeneratedSegmentCount()
        )
    } catch {
        await playback.sealGeneratedInput(
            finalExpectedSegmentCount: nextGlobalIndex
        )
        await playback.waitUntilPlaybackFinished()
        await renderSession.cancel(reason: error.localizedDescription)
        throw error
    }
}
```

The production implementation should retain the demo's rolling current/next
section preparation. The pseudocode above shows the ownership boundary; it may use
an `AsyncThrowingStream<TuringAudiobookSectionSegmentationResult, Error>` to make
the rolling window reusable.

The pseudocode spells out ScriptPoint05 for readability. The committed production
coordinator must use the stage-executor loop above rather than direct
`pipeline.stages[0]` / `pipeline.stages[1]` assumptions.

## 7.5 Exact promptVoice dependency

ScriptPoint05 promptVoice receives only:

```text
character profile
authored prompt context
the normalized ScriptPoint05 headline source as the prior spoken transcript
```

It does not receive:

```text
conversation history
checkpoint state
room state
previous generated turns
ScriptPoint04 dialogue history
duplicate copies of the headline in promptContext
```

The `stageSourceTranscript` descriptor means:

```swift
VoicePromptRequest(
    id: promptDescriptor.voicePromptID,
    characterProfileID: promptDescriptor.characterProfileID,
    promptContext: promptVoiceSeed.promptContext,
    prerecordingTranscript: sourcePlan.normalizedSourceText
)
```

The Foundation prompt may begin only after every scriptVoice source section has
been accepted, rendered by Qwen, decoded, and published to the playback owner.
It may compute while already published scriptVoice audio is still playing. Its
generated audio must use later global indexes, so it cannot play before
scriptVoice's actual ordered playback completes.

This distinguishes two events:

```text
scriptVoicePlanCommitted
  all source sections accepted and impossible for promptVoice to discard

scriptVoiceRenderCompleted
  every scriptVoice segment decoded and published to ordered playback

scriptVoicePlaybackCompleted
  the final scriptVoice audio handle completed
```

PromptVoice Foundation starts after `scriptVoiceRenderCompleted`. PromptVoice
audio starts only after `scriptVoicePlaybackCompleted` because the playback queue
owns strict global ordering.

---

# 8. Failure policy

## scriptVoice section Foundation failure

Use the established audiobook behavior:

```text
malformed JSON
-> one fresh-session JSON repair

guardrail or unrepaired section failure
-> log exact section and reason
-> do not send that section to Qwen
-> continue later sections when present
```

If no scriptVoice section commits, ScriptPoint05 fails with the visible message:

```text
Device operation failed.
```

## promptVoice Foundation failure

```text
promptVoice fails
-> record promptVoice stage failure
-> do not append promptVoice indexes
-> do not cancel scriptVoice Qwen
-> do not remove prepared scriptVoice WAV files
-> do not set expected count to zero
-> seal at the committed scriptVoice count
-> let scriptVoice finish through real playback callbacks
-> show Device operation failed after committed playback settles
```

## Qwen segment failure

Use the character runtime's existing `skipSegmentFailures` policy. A failed
segment must advance through `qwenComputeSkipped` without blocking later indexes.
Do not create a ScriptPoint05-specific Qwen policy.

## Cancellation

On immersive shutdown or explicit flow cancellation:

```text
cancel current/next Foundation tasks
cancel promptVoice task
cancel staged render session
seal/cancel playback through its existing owner
unload Fresh2 exactly once
release the character-pool arbiter exactly once
```

---

# 9. Files to change

Add:

```text
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringStagedSpeechRunCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringCommittedSpeechStage.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringCharacterQwenRenderSession.swift
```

Modify:

```text
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowEngine.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringCharacterQwenRenderer.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/Speech/TuringVoiceScriptLongformRunner.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowCompositeSpeechPlanner.swift
Gravitas Plague/Gravitas PlagueTests/TuringFlowResourceParityTests.swift
```

`TuringFlowCompositeSpeechPlanner` should either be removed from the active path or
reduced to descriptor/source validation. It must not return one flat array that is
withheld until every Foundation stage succeeds.

Do not change:

```text
ScriptPoint01-04 voicePrompt/conversationPrompt contracts
Fresh2 render/decode scheduler policy
Big Mike clone profile
Big Mike playback gain/speed
walkie spatial route
filler catalog or cadence
room scanning or prop placement
Battle01
Horde mode
```

---

# 10. Required telemetry

For ScriptPoint05, the device log must show this order:

```text
[TuringStagedSpeech] run started
  scriptPointID: prologue.scriptPoint05

[TuringPhase1Audiobook] source normalized
[TuringPhase1Audiobook] source section planned
[TuringFoundation] audiobook section segmentation accepted
  segmentCount: 11

[TuringStagedSpeech] stage committed
  stageID: headlineReading.section0
  kind: scriptVoice
  globalRange: 0..<11

[TuringFlow] Fresh2 pool ready
  actualInstanceCount: 2

[TuringFlow] exact Qwen input
  segmentIndex: 0
  BEGIN_TEXT
Rich, listen to this shit.
  END_TEXT

[TuringPlaybackRebuild] generated segment published
  segmentIndex: 0

[TuringPlaybackRebuild] generated playback started
  segmentIndex: 0

[TuringPlaybackRebuild] generated segment published
  segmentIndex: 10

[TuringStagedSpeech] stage render completed
  stageID: headlineReading
  globalRange: 0..<11

[TuringVoicePrompt] Foundation request started
  id: prologue.bigMike.scriptPoint05.followUp.001

[TuringStagedSpeech] stage committed
  stageID: personalFollowUp
  kind: promptVoice
  globalRange: 11..<N

[TuringPlaybackRebuild] generated playback completed
  segmentIndex: 10

[TuringPlaybackRebuild] generated playback started
  segmentIndex: 11

[TuringStagedSpeech] input sealed
  finalExpectedSegmentCount: N
```

If promptVoice guardrails trigger, required order is:

```text
scriptVoice stage committed 0..<11
scriptVoice Qwen input 0
scriptVoice audio published 0
promptVoice Foundation failed
input sealed finalExpectedSegmentCount=11
scriptVoice playback completes
Device operation failed
```

Rejected:

```text
scriptVoice segmentation accepted
promptVoice failed
expectedGeneratedSegmentCount=0
```

Rejected:

```text
promptVoice Foundation started
scriptVoice segment 10 published
```

Rejected:

```text
promptVoice generated playback started
scriptVoice segment 10 playback completed
```

---

# 11. Required tests

Unit tests:

```text
testScriptVoiceNormalizerMatchesAudiobookDemo
testScriptVoiceSourcePlanUsesEstablishedSectionPolicy
testScriptVoiceSegmentationPromptContainsOnlyCurrentSection
testScriptVoiceSegmentationUsesFreshFoundationSession
testMalformedSectionJSONGetsOneFreshRepair
testAcceptedSectionPreservesReturnedSegmentOrder
testAcceptedSectionCommitsStableGlobalRange
testPromptVoiceDoesNotStartBeforeScriptVoiceRenderCompletes
testPromptVoiceUsesNormalizedScriptSourceTranscript
testPromptVoiceInputContainsNoDialogueHistory
testPromptVoiceFailureDoesNotDiscardCommittedScriptVoice
testPromptVoiceFailureSealsAtScriptVoiceCountNotZero
testPromptVoiceIndexesFollowAllScriptVoiceIndexes
testFresh2PoolRemainsResidentAcrossBothStages
testExactlyTwoFreshInstancesRemainConfigured
testDecodedSegmentPublishesImmediately
testPlaybackCursorMovesOnlyFromActualHandleCompletion
testLegacySingleVoicePromptPathStillUsesCompatibilityRenderer
```

Mandatory integration test using controlled continuations:

```text
1. Return one accepted script section with two segments.
2. Observe stage commit at 0..<2.
3. Release Qwen segments 0 and 1 and assert both publish.
4. Assert promptVoice Foundation starts only after both publications.
5. Fail promptVoice with a synthetic guardrail error while scriptVoice playback is active.
6. Assert expected count seals at 2, never 0.
7. Complete playback handles 0 and 1.
8. Assert the run reports scriptVoice playback plus promptVoice stage failure.
```

Device acceptance:

```text
ScriptPoint04 completes and automatically enters ScriptPoint05.
Ten seconds of send static/filler occur.
ScriptPoint05 PR plays.
The complete ATNV-15 headline is heard in Big Mike's generated voice.
The personal follow-up plays only after the headline.
Filler bridges PR to the first generated headline segment.
Ambient walkie static remains under the walkie route.
The microphone returns after actual final playback completion.
No accepted scriptVoice stage is lost when promptVoice fails.
```

---

# 12. Static rejection checks

The completed implementation must satisfy equivalent checks:

```bash
! rg -n \
  'scriptSegments \+ resolvedPrompt\.segments' \
  "Gravitas Plague/Gravitas Plague/Turing/Flow"

! rg -n \
  'setExpectedGeneratedSegmentCount\([[:space:]]*0' \
  "Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowEngine.swift"

rg -n \
  'stage committed|sealGeneratedInput|renderStage' \
  "Gravitas Plague/Gravitas Plague/Turing"

rg -n \
  'TuringVoiceScriptLongformRunner|TuringPhase1AudiobookRunner' \
  "Gravitas Plague/Gravitas Plague/Turing/Flow/TuringStagedSpeechRunCoordinator.swift"
```

The first check removes the all-or-nothing flattened composite. The second prevents
a downstream plan failure from erasing committed generated work.

Production code must not call `TuringNativeQwenHelloWorldCanary`. The canary is the
behavioral reference. Extract or reuse its lower production layers through
`TuringVoiceScriptLongformRunner`, the Fresh2 scheduler, the production character
render session, and `TuringStoryWalkiePlaybackCoordinator`.

---

# 13. Completion report required from Codex

Do not report this complete based on compilation alone. Return:

```text
files changed
active ScriptPoint05 call chain
source normalization proof
source-section plan proof
exact Foundation segmentation prompt
raw segmentation response
accepted scriptVoice segment list
stage commit global range
first exact Qwen scriptVoice input
first scriptVoice decoded publication
first scriptVoice actual playback start
promptVoice Foundation start relative to scriptVoice commit
promptVoice global range
proof promptVoice cannot play before scriptVoice
promptVoice-failure test result
final generated input count
Fresh instance count
decoder concurrency
actual playback completion proof
Vision Pro ScriptPoint04-to-05 result
remaining failure boundary, if any
```

The implementation is not complete until the device log contains a real
ScriptPoint05 scriptVoice Qwen input and a real generated playback start for the
headline.
