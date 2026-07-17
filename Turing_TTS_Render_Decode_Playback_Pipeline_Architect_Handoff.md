# Turing TTS Render, Decode, and Concurrent Playback Pipeline

Status: Architect implementation handoff

Repository:

```text
/Users/richardfallat/Projects/dev/gravitas-plague
```

## Objective

Replace the current opaque render/decode handoff with one bounded, observable,
per-segment pipeline:

```text
1. Turing TTS render produces CPU-owned codebook rows.
2. Turing TTS decode converts one rendered segment to PCM.
3. The decoded segment is published immediately to ordered playback.
4. Rendering, decoding, and playback continue concurrently for later segments.
```

The required steady state is:

```text
Fresh worker 0: render segment 2
Fresh worker 1: waiting with rendered rows for segment 1
Decoder:        decode segment 1
Playback:       play segment 0
```

This is a bounded pipeline, not three batch phases. There must never be an
"render every segment, then decode every segment, then play" barrier.

## Non-negotiable behavior

1. Exactly two Fresh Qwen render workers remain active until all segment
   requests are exhausted.
2. Each worker processes one segment through render and decode before taking
   its next segment.
3. Codebook rendering may run concurrently on both Fresh workers.
4. Speech decoding is globally serialized to one active decoder because it is
   the MLX high-watermark stage.
5. A decoder waiting for its permit must retain CPU codebook rows only. It must
   not retain request-local MLX/KV working state.
6. Decode must not wait for all active rendering to finish.
7. As soon as segment N is decoded, it is postprocessed, written to a validated
   WAV, and published to the playback queue.
8. Playback starts segment N as soon as N is the next ordered segment and no
   generated clip is active.
9. Segment N+1 may render and decode while segment N is playing.
10. Segment N+1 may never replace or stop segment N.
11. Queue advancement comes only from the exact active playback handle's real
    completion callback.
12. No duration estimate or sleep may advance generated playback.
13. No ScriptPoint-specific renderer, decoder, scheduler, or playback path is
    permitted. ScriptPoint01, ScriptPoint02, ScriptPoint03, audiobook, and
    future Turing Flows must use the same pipeline.
14. Foundation prompts, prompt context, clone profiles, sampling, filler rules,
    routing, gain, 0.85 playback processing, and voice identities are outside
    this change.
15. Qwen render, speech decode, postprocessing, WAV I/O, and audio resource
    preparation must remain off MainActor. Only RealityKit entity/controller
    mutation may run on MainActor.

## Crash evidence

Device log:

```text
/Users/richardfallat/.codex/attachments/
1ce3bfa1-ce25-44a6-bd29-2381cf49ca21/pasted-text.txt
```

The failed run reported:

```text
[TuringQwenFresh2] run started
  physFootprintMB: 1518.2

[TuringQwenNativeBaseClone] dynamic codebook generation finished
  rowCount: 42

[TuringQwenSpeechDecodeGate] acquired
  decodeID: 0
  totalRows: 66
  physFootprintBeforeMB: 4729.0
```

The process then ended. The following required events never appeared:

```text
[TuringQwenSpeechDecodeGate] released
[TuringQwenFresh2] segment finished
[TuringPlaybackRebuild] qwen postprocess requested
[TuringPlaybackRebuild] generated wav written
[TuringPlaybackTrace] generated playback request
[TuringPlaybackRebuild] generated playback started
```

Therefore the observed user boundary is "playback should start now," but the
last proven code boundary is the first speech decode. The fix must make that
boundary memory-safe without delaying playback until every segment renders.

A working ScriptPoint01 conversation used the same Big Mike route and entered
its first decoder at 4303.3 MB with 41 generated rows. The failed segment had
42 rows. Prompt size and segment size do not explain the failure.

## Current production call chain

```text
TuringFlowConversationRunner.run
  -> TuringCharacterQwenRenderer.render
  -> TuringQwenNativeFreshInstancePool (exactly two instances)
  -> TuringQwenNativeFreshInstanceScheduler.renderSegments
  -> TuringQwenNativeFreshInstance.generate
  -> TuringQwenNativeBaseCloneEngine.generateBaseClone
       -> generateCodebookForDecode
       -> TuringQwenNativeSpeechDecodeGate.shared.decode
       -> TuringQwenNativeSpeechDecoder.decode
  -> onSegmentFinished
  -> TuringStoryWalkiePlaybackCoordinator.qwenComputeFinished
       -> postprocess
       -> write validated WAV
       -> pendingGenerated[segmentIndex]
       -> reconcile
       -> play exact next segment
```

Relevant files:

```text
Gravitas Plague/Gravitas Plague/Turing/Flow/
  TuringCharacterQwenRenderer.swift
  TuringFlowConversationRunner.swift

Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/
  TuringQwenNativeFreshInstance.swift
  TuringQwenNativeFreshInstancePool.swift
  TuringQwenNativeFreshInstanceScheduler.swift
  TuringQwenNativeBaseCloneEngine.swift
  TuringQwenNativeSpeechDecodeGate.swift
  TuringQwenNativeSpeechDecoder.swift

Gravitas Plague/Gravitas Plague/Turing/Audio/
  TuringStoryWalkiePlaybackCoordinator.swift
  TuringGeneratedPlaybackFileStore.swift
  TuringQwenOutputPostProcessor.swift
  TuringSpatialAudioEndpoint.swift
  TuringRealityAudioResourceLoader.swift
  TuringRealityKitAudioSceneBridge.swift
```

## Current ownership defect

`TuringQwenNativeBaseCloneEngine.generateBaseClone` currently hides both major
phases in one method:

```swift
let generated = try generateCodebookForDecode(prompt)

let fullAudio = try await TuringQwenNativeSpeechDecodeGate.shared.decode(
    codebookRows: rowsForDecode,
    modelRoot: modelRoot,
    performanceMode: prompt.performanceMode,
    queuedAt: decodeQueuedAt
)
```

This is per-segment in control flow, but it does not expose a contract proving
that the render working set is gone before the decoder allocates its working
set. The Fresh instance calls `releaseRequestLocalState()` only after
`generateBaseClone` returns, which is after decode:

```swift
let audio = try await engine.generateBaseClone(prompt: prompt)
await releaseRequestLocalState()
return audio
```

The current decoder is also a static function that reconstructs its config,
safetensors index, and reader for every segment:

```swift
let config = try TuringQwenNativeSpeechTokenizerConfig.load(from: modelRoot)
let tensorIndex = try TuringQwenNativeSafetensorsIndex.load(
    from: modelRoot
        .appendingPathComponent("speech_tokenizer")
        .appendingPathComponent("model.safetensors")
)
let reader = TuringQwenNativeSafetensorsReader(index: tensorIndex)
```

The global decode actor correctly limits decoder concurrency to one, but it
must own a run-scoped decoder session and explicit phase telemetry. It must not
own generation admission or wait for `activeGenerationCount == 0`.

## Target architecture

```text
TuringCharacterQwenRenderer
  owns one render run
  owns exactly two Fresh render workers
  owns one run-scoped decoder lease

TuringQwenNativeFreshInstanceScheduler
  assigns ordered requests to two workers
  each worker repeats:
    render codebook rows
    release render working set
    await serial decoder
    publish decoded PCM
    take next request

TuringQwenNativeSpeechDecodeCoordinator
  owns one decoder session for the run
  allows exactly one active decode
  does not gate render workers

TuringStoryWalkiePlaybackCoordinator
  receives each decoded segment immediately
  postprocesses and writes one WAV
  stores pending segments by index
  plays only nextPlaybackSegmentIndex
  advances only on exact handle completion
```

## Data contracts

Add a CPU-only payload between render and decode. It must not contain any
`MLXArray`, model object, KV cache, prompt embedding, or decoder tensor.

```swift
public struct TuringQwenRenderedCodebookSegment: Sendable {
    public let runID: String
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let segmentIndex: Int
    public let referenceRows: [[Int]]
    public let generatedRows: [[Int]]
    public let reachedEOS: Bool
    public let performanceMode: TuringQwenNativePerformanceMode
    public let renderMetrics: TuringQwenRenderPhaseMetrics

    public var rowsForDecode: [[Int]] {
        Array(referenceRows.suffix(24)) + generatedRows
    }
}

public struct TuringQwenDecodedSegment: Sendable {
    public let runID: String
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let segmentIndex: Int
    public let audio: TuringQwenNativeAudio
    public let renderMetrics: TuringQwenRenderPhaseMetrics
    public let decodeSeconds: TimeInterval
}

public struct TuringQwenRenderPhaseMetrics: Sendable {
    public let initialPromptSeconds: TimeInterval
    public let initialTalkerForwardSeconds: TimeInterval
    public let talkerOneStepTotalSeconds: TimeInterval
    public let codePredictorTotalSeconds: TimeInterval
}
```

Do not hardcode `24` at multiple call sites. Move the existing
`decodeReferenceContextRows` value into one shared configuration constant.

## Split the base-clone engine into explicit phases

Replace the opaque `generateBaseClone` ownership with an explicit render
method. Preserve the current prompt construction, clone artifacts, sampling,
EOS handling, and quality validation.

```swift
public actor TuringQwenNativeBaseCloneEngine {
    public func renderCodebook(
        request: TuringQwenNativeBaseCloneSegmentRequest,
        runID: String,
        instanceID: TuringQwenNativeFreshInstanceID
    ) throws -> TuringQwenRenderedCodebookSegment {
        let prompt = makePrompt(from: request)
        let generated = try generateCodebookForDecode(prompt)

        try prompt.generationQualityPolicy.validateBeforeDecode(
            voiceID: prompt.cloneProfile.voiceID,
            generatedRowCount: generated.generatedRows.count,
            maxNewRows: prompt.maxNewRows,
            reachedEOS: generated.reachedEOS
        )

        let result = TuringQwenRenderedCodebookSegment(
            runID: runID,
            instanceID: instanceID,
            segmentIndex: request.segmentIndex,
            referenceRows: generated.referenceRows,
            generatedRows: generated.generatedRows,
            reachedEOS: generated.reachedEOS,
            performanceMode: request.performanceMode,
            renderMetrics: .init(
                initialPromptSeconds: generated.initialPromptSeconds,
                initialTalkerForwardSeconds: generated.initialTalkerForwardSeconds,
                talkerOneStepTotalSeconds: generated.talkerOneStepTotalSeconds,
                codePredictorTotalSeconds: generated.codePredictorTotalSeconds
            )
        )

        releaseRequestWorkingSet(
            reason: "codebookReady.\(runID).\(request.segmentIndex)"
        )

        return result
    }

    private func releaseRequestWorkingSet(reason: String) {
        // Clear request-local prompt/KV/temporary arrays only.
        // Retain this Fresh worker's resident model weights until the run ends.
        clearRequestLocalCaches()
        TuringQwenNativeMemoryControl.clearCache(
            label: "baseClone.renderPhaseReleased.\(reason)",
            shouldLogSnapshot: true
        )
    }
}
```

The architect must audit every property retained by
`TuringQwenNativeBaseCloneEngine`. Anything derived from a specific target
segment must be cleared before `renderCodebook` returns. Only immutable clone
conditioning and the Fresh instance's resident model resources may survive.

Do not call `releaseResidentState()` after every segment if it unloads the
Fresh worker's resident model. Fresh2 must remain warm until the work queue is
exhausted. Add a separate request-local cleanup API rather than reusing an API
whose name and behavior are resident-state teardown.

## Run-scoped serialized decoder

Replace the static decoder reconstruction with a run-scoped session owned by
one actor. The session loads immutable decoder metadata once per Turing render
run and releases it when all segment decodes finish.

```swift
final class TuringQwenNativeSpeechDecoderSession {
    let modelRoot: URL
    let config: TuringQwenNativeSpeechTokenizerConfig
    let reader: TuringQwenNativeSafetensorsReader

    init(modelRoot: URL) throws {
        self.modelRoot = modelRoot
        self.config = try TuringQwenNativeSpeechTokenizerConfig.load(
            from: modelRoot
        )
        let index = try TuringQwenNativeSafetensorsIndex.load(
            from: modelRoot
                .appendingPathComponent("speech_tokenizer")
                .appendingPathComponent("model.safetensors")
        )
        self.reader = TuringQwenNativeSafetensorsReader(index: index)
    }

    func decode(rows: [[Int]]) throws -> TuringQwenNativeAudio {
        // Move the existing TuringQwenNativeSpeechDecoder.decode body here.
        // Use this session's config and reader. Do not rebuild them per segment.
        try decodeRows(rows, config: config, reader: reader)
    }
}

public actor TuringQwenNativeSpeechDecodeCoordinator {
    public struct RunToken: Hashable, Sendable {
        public let id: UUID
        public let runID: String
    }

    private struct ActiveRun {
        let token: RunToken
        let session: TuringQwenNativeSpeechDecoderSession
    }

    private var activeRun: ActiveRun?
    private var nextDecodeID = 0

    public func beginRun(
        runID: String,
        modelRoot: URL
    ) throws -> RunToken {
        precondition(activeRun == nil)
        let token = RunToken(id: UUID(), runID: runID)
        activeRun = ActiveRun(
            token: token,
            session: try TuringQwenNativeSpeechDecoderSession(
                modelRoot: modelRoot
            )
        )
        return token
    }

    public func decode(
        _ rendered: TuringQwenRenderedCodebookSegment,
        token: RunToken
    ) throws -> TuringQwenDecodedSegment {
        guard let activeRun, activeRun.token == token else {
            throw TuringQwenNativeError.invalidConfig(
                "Decode token does not own the active Turing render run."
            )
        }

        let decodeID = nextDecodeID
        nextDecodeID += 1
        let before = TuringQwenNativeProcessMemoryProbe.snapshot()
        let startedAt = Date()

        print("""
        [TuringSegmentPipeline] decode acquired
          runID: \(rendered.runID)
          segmentIndex: \(rendered.segmentIndex)
          instanceID: \(rendered.instanceID.rawValue)
          decodeID: \(decodeID)
          totalRows: \(rendered.rowsForDecode.count)
          physFootprintBeforeMB: \(before.physFootprintMB)
          concurrentDecoderLimit: 1
        """)

        let fullAudio = try activeRun.session.decode(
            rows: rendered.rowsForDecode
        )
        let trimmed = try TuringQwenNativeBaseCloneDecodeTrimmer
            .trimReferencePrefix(
                from: fullAudio.samples,
                referenceRowCount: min(
                    rendered.referenceRows.count,
                    TuringQwenDecodeConfiguration.referenceContextRows
                ),
                totalRowCount: rendered.rowsForDecode.count
            )
        let audio = TuringQwenNativeAudio(
            samples: trimmed,
            sampleRate: fullAudio.sampleRate
        )

        TuringQwenNativeMemoryControl.clearCache(
            label: "speechDecoder.segmentCompleted.\(rendered.segmentIndex)",
            shouldLogSnapshot: true
        )

        return TuringQwenDecodedSegment(
            runID: rendered.runID,
            instanceID: rendered.instanceID,
            segmentIndex: rendered.segmentIndex,
            audio: audio,
            renderMetrics: rendered.renderMetrics,
            decodeSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    public func finishRun(_ token: RunToken) {
        guard activeRun?.token == token else { return }
        activeRun = nil
        TuringQwenNativeMemoryControl.clearCache(
            label: "speechDecoder.runFinished.\(token.runID)",
            shouldLogSnapshot: true
        )
    }
}
```

`TuringQwenNativeSpeechDecoderSession` must stay actor-confined. Do not mark its
MLX or reader objects `@unchecked Sendable` merely to silence the compiler.

## Fresh2 segment pipeline scheduler

The scheduler must process each request end-to-end on one Fresh worker while
sharing the single decoder coordinator:

```swift
public func renderSegments(
    _ requests: [TuringQwenNativeBaseCloneSegmentRequest],
    runID: String,
    modelRoot: URL,
    onSegmentStarted: @Sendable @escaping (Int) async -> Void,
    onSegmentDecoded: @Sendable @escaping (
        TuringQwenDecodedSegment
    ) async throws -> Void,
    onSegmentSkipped: @Sendable @escaping (Int, String) async -> Void
) async throws -> TuringQwenNativeFreshInstanceRunReport {
    let instances = try await instancePool
        .warmedInstancesExactlyRequestedCount()
    precondition(instances.count == 2)

    let decodeToken = try await decodeCoordinator.beginRun(
        runID: runID,
        modelRoot: modelRoot
    )
    defer {
        Task {
            await decodeCoordinator.finishRun(decodeToken)
        }
    }

    let workQueue = TuringQwenNativeFreshInstanceWorkQueue(
        totalCount: requests.count
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for instance in instances {
            group.addTask {
                while let requestIndex = await workQueue.nextIndex() {
                    let request = requests[requestIndex]
                    await onSegmentStarted(request.segmentIndex)

                    do {
                        let rendered = try await instance.renderCodebook(
                            request,
                            runID: runID
                        )

                        // This await serializes only decode. The other Fresh
                        // worker may continue rendering independently.
                        let decoded = try await decodeCoordinator.decode(
                            rendered,
                            token: decodeToken
                        )

                        // Publish immediately. Do not wait for another segment.
                        try await onSegmentDecoded(decoded)
                    } catch {
                        if skipSegmentFailures {
                            await onSegmentSkipped(
                                request.segmentIndex,
                                error.localizedDescription
                            )
                            continue
                        }
                        throw error
                    }
                }
            }
        }

        try await group.waitForAll()
    }
}
```

Do not implement any of the following:

```text
render all -> group.waitForAll -> decode all
activeGenerationCount == 0 before decode
decode all -> sort -> publish all
await qwenComputeAllFinished before first playback
two simultaneous speech decoders
unbounded decoded PCM buffering
```

## Immediate publication into ordered playback

Keep the existing callback boundary in `TuringCharacterQwenRenderer`, but name
it according to the actual event:

```swift
onSegmentDecoded: { decoded in
    await state.recordSuccess(decoded.segmentIndex)

    await playback.qwenComputeFinished(
        segmentIndex: decoded.segmentIndex,
        audio: TuringComputeGapGeneratedAudio(
            segmentIndex: decoded.segmentIndex,
            samples: decoded.audio.samples,
            sampleRate: Double(decoded.audio.sampleRate),
            channelCount: 1
        )
    )
}
```

`qwenComputeFinished` must continue to perform this bounded handoff:

```text
decoded PCM
-> character output postprocess, including configured 0.85 processing
-> write segment_N.tmp.wav
-> close writer
-> atomically move to segment_N.wav
-> reopen and validate
-> pendingGenerated[N] = file-backed clip
-> release PCM after callback returns
-> reconcile ordered playback immediately
```

The pending queue must hold file metadata, not decoded sample arrays:

```swift
private var pendingGenerated: [
    Int: TuringGeneratedPlaybackFileStore.PreparedClip
] = [:]
```

The existing ordered playback invariant must remain:

```swift
private func startGeneratedIfReady() async {
    guard activeItem == .none else { return }
    guard let clip = pendingGenerated.removeValue(
        forKey: nextPlaybackSegmentIndex
    ) else { return }
    await startGenerated(clip, reason: "nextDecodedSegmentReady")
}
```

The completion callback remains the only advancement authority:

```swift
case .generated(
    let segmentIndex,
    let activeHandle,
    let fileURL,
    _
) where activeHandle == completedHandle:
    nextPlaybackSegmentIndex = segmentIndex + 1
    completedGeneratedPlaybackCount += 1
    activeItem = .none
    await endpoint.evictTransient(fileURL: fileURL)
    await fileStore.delete(
        fileURL: fileURL,
        runID: activeHandle.runID,
        segmentIndex: segmentIndex,
        reason: "generatedPlaybackCompleted"
    )
    await reconcile(reason: "generatedCompleted")
```

No later render or decode event may call `stop` on generated playback.

## Backpressure and bounded memory

The pipeline must enforce these hard bounds:

```text
active Fresh render workers:       2
active speech decoders:            1
rendered codebook payloads waiting: at most 1 per Fresh worker
decoded PCM callback payloads:     at most 1 per Fresh worker
active generated playback:         1
pending generated playback files:  bounded by remaining segment count
```

Do not add an arbitrary memory threshold that changes behavior, disables a
Fresh worker, skips decoding, or falls back to another TTS implementation.
Memory instrumentation is diagnostic. Correct ownership and bounded lifetime
must make the normal pipeline safe.

Required cleanup points:

```text
after codebook rows become CPU-owned:
  release request-local render/KV arrays
  clear reusable MLX cache

after decoded PCM is copied to Swift storage:
  release decoder hidden tensors
  clear reusable MLX cache

after WAV publication:
  release decoded and postprocessed sample arrays

after actual playback completion:
  evict transient AudioFileResource
  delete exact WAV

after render queue exhaustion:
  unload both Fresh instances
  release run-scoped decoder session
  clear MLX cache
```

## MainActor boundary

These operations must not run on MainActor:

```text
Foundation response parsing
Fresh2 model warm load
codebook render
speech decode
postprocessing/time stretch
WAV write and validation
AudioFileResource preparation
queue bookkeeping
filler/dead-air timers
```

Only these operations may cross to MainActor:

```text
RealityKit Entity creation/removal
SpatialAudioComponent mutation
Entity.playAudio
AudioPlaybackController stop/completion-handler installation
visible HUD/icon state
```

Do not move Qwen or playback coordinator actors onto MainActor to resolve
compiler isolation errors.

## Required telemetry

Every segment must emit these breadcrumbs with `runID`, `segmentIndex`, and
`instanceID`:

```text
[TuringSegmentPipeline] render started
[TuringSegmentPipeline] render completed
[TuringSegmentPipeline] render working set released
[TuringSegmentPipeline] decode queued
[TuringSegmentPipeline] decode acquired
[TuringSegmentPipeline] decode completed
[TuringSegmentPipeline] decode working set released
[TuringSegmentPipeline] audio publish started
[TuringSegmentPipeline] audio published
[TuringPlaybackRebuild] generated playback started
[TuringPlaybackRebuild] generated playback completed
[TuringSegmentPipeline] worker advanced
```

Each phase boundary must include:

```text
physFootprintMB
residentSizeMB
MLX active MB
MLX cache MB
elapsed seconds
generated row count or sample count as applicable
```

The expected interleaving for a five-segment response is:

```text
render started 0 on fresh-0
render started 1 on fresh-1
render completed 0
decode acquired 0
render completed 1
decode completed 0
audio published 0
playback started 0
worker fresh-0 advanced to render 2
decode acquired 1
render started 2
decode completed 1
audio published 1
worker fresh-1 advanced to render 3
playback completed 0
playback started 1
```

An implementation is rejected if `audio published 0` appears only after all
five `render completed` events.

## Failure and cancellation

1. A render failure follows the existing character runtime's
   `skipSegmentFailures` policy.
2. A decode failure is attributed to that exact segment and follows the same
   skip policy. It must not poison the decoder token for later segments.
3. Skipping the current next index must notify playback so it can advance to
   the next non-skipped index without a duration estimate.
4. Cancellation stops assignment of new work, cancels queued decoder requests,
   unloads both Fresh instances, ends the decoder run, clears transient PCM,
   and asks playback to cancel only that run ID.
5. A stale decoder result from a cancelled run must be discarded by run ID.
6. A stale playback completion must not advance the active run.

## Tests

Add focused tests for the architecture, not only string audits.

### Pipeline concurrency

```text
testTwoFreshWorkersRenderConcurrently
testDecoderConcurrencyNeverExceedsOne
testDecodeDoesNotWaitForAllRendering
testWorkerTakesNextSegmentAfterItsDecodePublishes
testSegmentZeroPublishesWhileLaterSegmentsStillRender
```

Use controllable fake renderers and decoder continuations. Assert event order,
not elapsed wall-clock guesses.

### Playback ordering

```text
testDecodedSegmentOneWaitsWhenSegmentZeroIsNotReady
testSegmentOneCannotReplacePlayingSegmentZero
testActualHandleCompletionAdvancesExactlyOnce
testStaleCompletionCannotAdvanceQueue
testWAVDeletedOnlyAfterActualCompletion
testPCMIsNotRetainedAfterWAVPublication
```

### Memory ownership

```text
testRenderedPayloadContainsNoMLXObjects
testRequestWorkingSetReleasedBeforeDecodeAcquisition
testDecoderSessionConstructedOncePerRun
testDecoderSessionReleasedAtRunEnd
testFreshResidentModelsRemainLoadedUntilQueueExhaustion
testTransientAudioResourceEvictedAfterPlaybackCompletion
```

### Cross-flow parity

```text
testScript01ConversationUsesSharedSegmentPipeline
testScript02PromptVoiceUsesSharedSegmentPipeline
testScript03ConversationUsesSharedSegmentPipeline
testAudiobookUsesSharedSegmentPipeline
testNoScriptPointSpecificRendererOrDecoderExists
```

## Device acceptance

Run on the target Vision Pro hardware with a five-to-six segment Big Mike
conversation after ScriptPoint03 and Battle01 cleanup.

Pass criteria:

1. Two Fresh workers are logged.
2. Segment 0 decode starts without waiting for all segments to render.
3. Segment 0 is published before all segments render.
4. Segment 0 playback begins while later render/decode work continues.
5. Playback remains spatially attached to the Story walkie emitter.
6. Every generated segment plays from beginning to actual completion.
7. No generated segment replaces another.
8. The process does not crash at decoder acquisition or playback publication.
9. No MainActor heartbeat hitch is introduced by render, decode, WAV I/O, or
   resource preparation.
10. Fresh2 stays at exactly two instances until the render queue is exhausted.
11. Decoder concurrency remains exactly one.
12. Microphone state returns only after the complete ordered playback run.

Repeat the same acceptance from ScriptPoint01. The renderer, decoder,
scheduler, playback owner, routing, and completion logs must name the same
types in both runs.

## Static rejection checks

Reject the patch if repository search finds any of these concepts in the
active Turing generated-speech path:

```text
decodeAfterAllGeneration
activeGenerationCount == 0
renderAllThenDecode
waitForAll before first segment publication
Task.sleep used as generated playback completion
duration estimate used as generated playback completion
ScriptPoint01QwenRenderer
ScriptPoint02QwenRenderer
ScriptPoint03QwenRenderer
second generated playback coordinator
two active speech decoders
AVAudioSession.setCategory(.playback)
```

## Frozen systems

This patch must not alter:

```text
Foundation prompt templates or fresh-session policy
character profiles
Big Mike or Rich clone artifacts
Qwen sampling policy
segment text
0.85 voice playback processing
filler assets, weights, cadence, or dead-air policy
walkie static/send-static behavior
spatial route selection
audio gain
room scanning or prop placement
Battle01 behavior
episode continuation checkpoints
dictation or system recording policy
```

## Completion report required from Codex

The implementation report must include:

```text
all files changed
the final render/decode/playback ownership diagram
proof of exactly two render workers and one decoder
proof segment 0 published before all rendering completed
proof actual playback completion advances the queue
before/after decoder memory snapshots from ScriptPoint01
before/after decoder memory snapshots after ScriptPoint03
Vision Pro device acceptance results
any remaining memory peak with exact phase ownership
```

No claim of completion is acceptable based only on compilation or static
inspection. The crash occurs on device at the render-to-decode boundary.
