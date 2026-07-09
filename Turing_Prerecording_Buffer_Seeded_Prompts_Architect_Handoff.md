# Turing Prerecording Buffer + Seeded voicePrompt / conversationPrompt Handoff

This handoff is for implementing:

```text
authored prerecording plays first through the Story walkie
voicePrompt computes while the prerecording plays
voicePrompt returns generated follow-up speech plus a conversation seed
seed is stored for Big Mike
later conversationPrompt receives player dictation plus prerecording transcript plus latest seed
if no seed exists, conversationPrompt receives an empty seed and continues
```

Hard boundaries:

```text
Do not touch Qwen native generation graph.
Do not touch Base clone profile artifacts.
Do not touch the two-fresh-instance MLX scheduler.
Do not touch audiobook source sectioning.
Do not touch filler assets.
Do not touch walkie wall placement.
Do not create a new HUD.
Do not add Bible or Focus.
Do not replace the current playback owner.
```

Current active systems:

```text
Dialogue service:
  Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringDialogueService.swift

Dialogue payloads:
  Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringDialoguePayloads.swift

Prompt resources:
  Gravitas Plague/TuringResources/Turing/Prompts/voicePrompt_characterIntent.txt
  Gravitas Plague/TuringResources/Turing/Prompts/conversationPrompt_playerTurn_noBible.txt

Playback owner:
  Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift

Low-level walkie clip player:
  Gravitas Plague/Gravitas Plague/Turing/Audio/TuringWalkieOneShotClipPlayer.swift

Current Qwen route:
  Gravitas Plague/Gravitas Plague/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift

Current character metadata:
  Gravitas Plague/TuringResources/Turing/Characters/big_mike.json

Current voice registry:
  Gravitas Plague/TuringResources/Turing/Config/voice-registry.json

Current safe Qwen scheduler:
  TuringQwenNativeGenerationSchedulerFactory.makeFresh2Pool()
  TuringQwenNativeGenerationSchedulerFactory.makeFresh2Scheduler(instancePool:)
```

## 1. Add Seed Model And Store

New file:

```text
Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringConversationSeed.swift
```

Code:

```swift
import Foundation

struct TuringConversationSeed: Codable, Sendable, Hashable {
    let seedID: String
    let summary: String
    let currentAttitude: String
    let recentFacts: [String]
    let openThread: String

    static let empty = TuringConversationSeed(
        seedID: "",
        summary: "",
        currentAttitude: "",
        recentFacts: [],
        openThread: ""
    )

    var isEmptySeed: Bool {
        seedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        currentAttitude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        recentFacts.isEmpty &&
        openThread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var promptJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

actor TuringConversationSeedStore {
    private var seedsByKey: [String: TuringConversationSeed] = [:]

    func seed(for key: String) -> TuringConversationSeed {
        seedsByKey[key] ?? .empty
    }

    func update(_ seed: TuringConversationSeed?, for key: String) {
        guard let seed else {
            return
        }

        if seed.isEmptySeed {
            seedsByKey.removeValue(forKey: key)
        } else {
            seedsByKey[key] = seed
        }
    }

    func clear(key: String) {
        seedsByKey.removeValue(forKey: key)
    }

    func clearAll(reason: String) {
        seedsByKey.removeAll(keepingCapacity: false)
        print("""
        [TuringConversationSeed] cleared
          reason: \(reason)
        """)
    }
}
```

MVP key recommendation:

```text
big_mike
```

Future key if multiple Big Mike targets diverge:

```text
walkieTalkie.bigMike
```

## 2. Extend Dialogue Payloads

Patch file:

```text
Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringDialoguePayloads.swift
```

Replace or extend request structs with this shape:

```swift
struct VoicePromptRequest: Codable, Sendable, Hashable {
    let id: String
    let speaker: String
    let voiceID: String
    let voiceVariantID: String?
    let characterProfileID: String
    let intent: String
    let emotion: String
    let prerecordingTranscript: String?
    let voicePromptSeedIntent: String?

    init(
        id: String,
        speaker: String,
        voiceID: String,
        voiceVariantID: String? = nil,
        characterProfileID: String,
        intent: String,
        emotion: String,
        prerecordingTranscript: String? = nil,
        voicePromptSeedIntent: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.voiceID = voiceID
        self.voiceVariantID = voiceVariantID
        self.characterProfileID = characterProfileID
        self.intent = intent
        self.emotion = emotion
        self.prerecordingTranscript = prerecordingTranscript
        self.voicePromptSeedIntent = voicePromptSeedIntent
    }
}

struct ConversationPromptNoBibleRequest: Codable, Sendable, Hashable {
    let id: String
    let speaker: String
    let voiceID: String
    let voiceVariantID: String?
    let characterProfileID: String
    let playerDictation: String
    let episodeStateForWordsOnly: String
    let emotion: String
    let prerecordingTranscript: String?
    let lastVoicePromptSeed: TuringConversationSeed?

    init(
        id: String,
        speaker: String,
        voiceID: String,
        voiceVariantID: String? = nil,
        characterProfileID: String,
        playerDictation: String,
        episodeStateForWordsOnly: String,
        emotion: String,
        prerecordingTranscript: String? = nil,
        lastVoicePromptSeed: TuringConversationSeed? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.voiceID = voiceID
        self.voiceVariantID = voiceVariantID
        self.characterProfileID = characterProfileID
        self.playerDictation = playerDictation
        self.episodeStateForWordsOnly = episodeStateForWordsOnly
        self.emotion = emotion
        self.prerecordingTranscript = prerecordingTranscript
        self.lastVoicePromptSeed = lastVoicePromptSeed
    }
}

struct TuringDialoguePlan: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let segments: [TuringSpeechSegment]
}

struct TuringVoicePromptPlan: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let segments: [TuringSpeechSegment]
    let conversationSeed: TuringConversationSeed?
}
```

Rationale:

```text
conversationPrompt can stay simple and does not need to return a seed for MVP.
voicePrompt gets the seed because it is the authored/setup turn.
voiceVariantID is optional now so existing callers do not break.
```

## 3. Patch voicePrompt Template

Patch resource:

```text
Gravitas Plague/TuringResources/Turing/Prompts/voicePrompt_characterIntent.txt
```

Replace with:

```text
You are writing one short spoken turn for a character in Gravitas Plague.

Character:
{{characterProfile}}

Prerecording transcript, if available:
"""
{{prerecordingTranscript}}
"""

Story intent:
{{intent}}

Seed intent:
{{voicePromptSeedIntent}}

Emotional tone:
{{emotion}}

Rules:
- Write only the character's spoken words.
- Keep the response in character.
- Do not include stage directions.
- Do not mention game systems, prompts, routing, files, props, HUD, buttons, microphones, audio, Qwen, MLX, Foundation Models, or JSON.
- Use the prerecording transcript only as recent context. Do not repeat it unless the character naturally would.
- Use the requested emotional tone unless the character profile and intent clearly require a more specific adjacent emotion.
- Segment the speech into natural 3 to 5 second spoken chunks.
- Every segment must include a short emotional performance description.
- Return a conversationSeed object that summarizes the situation for later player conversation.
- Return JSON only. No markdown. No prose outside JSON.
- Do not include extra keys.

Return this exact sparse JSON schema:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "string",
      "emotion": "string"
    }
  ],
  "conversationSeed": {
    "seedID": "string",
    "summary": "string",
    "currentAttitude": "string",
    "recentFacts": ["string"],
    "openThread": "string"
  }
}
```

## 4. Patch conversationPrompt Template

Patch resource:

```text
Gravitas Plague/TuringResources/Turing/Prompts/conversationPrompt_playerTurn_noBible.txt
```

Add these blocks before `Player said:`:

```text
Prerecording transcript, if available:
"""
{{prerecordingTranscript}}
"""

Latest voicePrompt seed. This may be empty:
{{lastVoicePromptSeed}}
```

Keep the return schema unchanged:

```json
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

Hard rule:

```text
If no seed exists, pass TuringConversationSeed.empty.promptJSON.
Do not fail conversationPrompt for missing seed.
```

## 5. Patch Dialogue Service

Patch file:

```text
Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringDialogueService.swift
```

Change `generateVoicePrompt` return type:

```swift
func generateVoicePrompt(
    _ request: VoicePromptRequest
) async throws -> TuringVoicePromptPlan
```

Render prompt replacements:

```swift
let prompt = try Self.renderPrompt(
    resourcePath: "Turing/Prompts/voicePrompt_characterIntent.txt",
    replacements: [
        "{{characterProfile}}": profile.promptText,
        "{{prerecordingTranscript}}": request.prerecordingTranscript ?? "",
        "{{intent}}": request.intent,
        "{{voicePromptSeedIntent}}": request.voicePromptSeedIntent ?? "",
        "{{emotion}}": request.emotion
    ]
)
```

Guardrail skip result:

```swift
return TuringVoicePromptPlan(
    schemaVersion: 1,
    segments: [],
    conversationSeed: nil
)
```

Decode voice prompt with seed:

```swift
private func decodeVoicePromptWithOneRepair(
    raw: String,
    purpose: String
) async throws -> TuringVoicePromptPlan {
    do {
        return try Self.decodeStrictVoicePromptPlan(raw)
    } catch {
        let repairService = TuringDialogueJSONRepairService(
            runner: runner
        )
        let repaired = try await repairService.repairJSON(
            invalidPayload: raw,
            errorDescription: error.localizedDescription
        )
        do {
            return try Self.decodeStrictVoicePromptPlan(repaired)
        } catch {
            throw TuringRuntimeError.foundationRepairFailed(
                "\(purpose): \(error.localizedDescription)"
            )
        }
    }
}

private static func decodeStrictVoicePromptPlan(
    _ raw: String
) throws -> TuringVoicePromptPlan {
    let data = try TuringJSONSanitizer.extractSingleTopLevelObject(
        from: raw
    )
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
        throw TuringRuntimeError.foundationJSONGateFailed(
            "Top-level response must be a JSON object."
        )
    }

    let allowedKeys: Set<String> = [
        "schemaVersion",
        "segments",
        "conversationSeed"
    ]
    let extraKeys = Set(dictionary.keys).subtracting(allowedKeys)
    guard extraKeys.isEmpty else {
        throw TuringRuntimeError.foundationJSONGateFailed(
            "Unexpected top-level keys: \(extraKeys.sorted().joined(separator: ", "))."
        )
    }

    let decoded = try JSONDecoder().decode(
        TuringVoicePromptPlan.self,
        from: data
    )

    guard decoded.schemaVersion == 1 else {
        throw TuringRuntimeError.foundationJSONGateFailed(
            "schemaVersion must be 1."
        )
    }

    let normalizedSegments = try decoded.segments.enumerated().map { index, segment in
        let text = segment.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let emotion = segment.emotion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard text.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "Segment \(index) text must not be empty."
            )
        }
        guard emotion.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "Segment \(index) emotion must not be empty."
            )
        }

        return TuringSpeechSegment(
            text: text,
            emotion: emotion
        )
    }

    return TuringVoicePromptPlan(
        schemaVersion: decoded.schemaVersion,
        segments: normalizedSegments,
        conversationSeed: decoded.conversationSeed
    )
}
```

Patch conversation prompt render replacements:

```swift
let seed = request.lastVoicePromptSeed ?? .empty
let prompt = try Self.renderPrompt(
    resourcePath: "Turing/Prompts/conversationPrompt_playerTurn_noBible.txt",
    replacements: [
        "{{characterProfile}}": profile.promptText,
        "{{episodeStateForWordsOnly}}": request.episodeStateForWordsOnly,
        "{{prerecordingTranscript}}": request.prerecordingTranscript ?? "",
        "{{lastVoicePromptSeed}}": seed.promptJSON,
        "{{playerDictation}}": request.playerDictation,
        "{{emotion}}": request.emotion
    ]
)
```

Do not make missing seed an error.

## 6. Add Prerecording Descriptor

New file:

```text
Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringPrerecordingDescriptor.swift
```

Code:

```swift
import Foundation

struct TuringPrerecordingDescriptor: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let prerecordingID: String
    let speaker: String
    let voiceID: String
    let voiceVariantID: String?
    let audioFile: String
    let transcriptMode: TranscriptMode
    let transcript: String
    let summary: String
    let voicePromptIntent: String
    let defaultEmotion: String

    enum TranscriptMode: String, Codable, Sendable {
        case manual
        case speechToText
        case none
    }
}

struct TuringPrerecordingStore: Sendable {
    func descriptor(
        id: String
    ) throws -> TuringPrerecordingDescriptor {
        try TuringResourceLoader.decodeResource(
            TuringPrerecordingDescriptor.self,
            resourcePath: "Turing/Prerecordings/\(id).json"
        )
    }

    func audioURL(
        for descriptor: TuringPrerecordingDescriptor
    ) throws -> URL {
        try TuringResourceLoader.resourceURL(
            resourcePath: "Turing/Audio/prerecordings/\(descriptor.audioFile)"
        )
    }
}
```

New resource:

```text
Gravitas Plague/TuringResources/Turing/Prerecordings/prologue.walkie.bigMike.checkIn.001.json
```

JSON:

```json
{
  "schemaVersion": 1,
  "prerecordingID": "prologue.walkie.bigMike.checkIn.001",
  "speaker": "big_mike",
  "voiceID": "big_mike_base_clone_v1",
  "voiceVariantID": "broadcast_reference_fast_01",
  "audioFile": "prologue_big_mike_checkin_001.wav",
  "transcriptMode": "manual",
  "transcript": "Hey Rich you there? Haven't heard from you in a minute. Do you copy? Over. Rich this is Big Mike! Do you copy? Over.",
  "summary": "Big Mike checks whether Rich can hear him and is worried because Rich missed the regular check-in cadence.",
  "voicePromptIntent": "You are asking if Rich can hear you. You are worried because you have not heard from Rich at your regular cadence and are worried Rich may have been attacked.",
  "defaultEmotion": "worried, controlled, protective"
}
```

New audio path:

```text
Gravitas Plague/TuringResources/Turing/Audio/prerecordings/prologue_big_mike_checkin_001.wav
```

If the file is MP3 instead of WAV, `TuringWalkieOneShotClipPlayer` can load it through `AudioFileResource.load(contentsOf:)`, but WAV is better for predictable playback.

## 7. Add Prerecording To Walkie Clip Player

Patch file:

```text
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringWalkieOneShotClipPlayer.swift
```

Patch enum:

```swift
enum ClipKind: String {
    case generated
    case prerecording
    case filler

    var laneName: String {
        switch self {
        case .generated:
            return "TuringWalkieAudio_GeneratedLane"
        case .prerecording:
            return "TuringWalkieAudio_PrerecordingLane"
        case .filler:
            return "TuringWalkieAudio_FillerLane"
        }
    }
}
```

Add storage:

```swift
private var prerecordingLane: Entity?
```

Patch lane selection:

```swift
let lane: Entity?
switch kind {
case .generated:
    lane = generatedLane
case .prerecording:
    lane = prerecordingLane
case .filler:
    lane = fillerLane
}
```

Patch `ensureLanes()`:

```swift
if prerecordingLane?.parent == nil {
    prerecordingLane = Self.makeLane(
        named: ClipKind.prerecording.laneName,
        under: walkieEmitter
    )
}
```

Do not use a separate playback owner for prerecording. This is only a lane for routing/debug visibility. Ordering is owned by `TuringStoryWalkiePlaybackCoordinator`.

## 8. Add Prerecording Item To Playback Coordinator

Patch file:

```text
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift
```

Add clip model:

```swift
private struct PrerecordingClip {
    let id: String
    let fileURL: URL
}
```

Patch `ActiveItem`:

```swift
case prerecording(
    id: String,
    handleID: UUID,
    fileURL: URL,
    startedAt: Date
)
```

Add state:

```swift
private var pendingPrerecording: PrerecordingClip?
private var prerecordingHasPlayed = false
```

Reset in `beginRun`:

```swift
self.pendingPrerecording = nil
self.prerecordingHasPlayed = false
```

Add public enqueue API:

```swift
func enqueuePrerecording(
    id: String,
    fileURL: URL
) async {
    guard runActive else { return }
    pendingPrerecording = PrerecordingClip(
        id: id,
        fileURL: fileURL
    )
    print("""
    [TuringPlaybackRebuild] prerecording queued
      id: \(id)
      file: \(fileURL.lastPathComponent)
      playsBeforeGenerated: true
    """)
    await reconcile(reason: "prerecordingQueued")
}
```

Patch `reconcile` before first filler/generated logic:

```swift
if prerecordingHasPlayed == false,
   let prerecording = pendingPrerecording {
    pendingPrerecording = nil
    await startPrerecording(prerecording, reason: reason)
    return
}
```

Add starter:

```swift
private func startPrerecording(
    _ clip: PrerecordingClip,
    reason: String
) async {
    guard activeItem == .none else {
        pendingPrerecording = clip
        return
    }
    guard let clipPlayer = TuringStoryWalkieAudioRoute.makeActiveClipPlayer() else {
        print("""
        [TuringPlaybackRebuild] prerecording playback blocked
          id: \(clip.id)
          reason: missingWalkieClipPlayer
          requiredEmitter: TuringStoryWalkieTalkie_AudioEmitter
        """)
        await runCancelled(reason: "missingWalkieClipPlayer.prerecording.\(clip.id)")
        return
    }

    do {
        let handleID = try clipPlayer.playOneShot(
            fileURL: clip.fileURL,
            kind: .prerecording,
            label: clip.id,
            completion: { [weak self] handleID in
                Task { @MainActor in
                    await self?.playbackCompleted(handleID: handleID)
                }
            }
        )
        activeItem = .prerecording(
            id: clip.id,
            handleID: handleID,
            fileURL: clip.fileURL,
            startedAt: Date()
        )
        print("""
        [TuringPlaybackRebuild] prerecording playback started
          id: \(clip.id)
          handleID: \(handleID.uuidString)
          file: \(clip.fileURL.lastPathComponent)
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
          completionGate: coordinatorActiveHandleMatch
        """)
    } catch {
        print("""
        [TuringPlaybackRebuild] prerecording playback failed
          id: \(clip.id)
          file: \(clip.fileURL.lastPathComponent)
          error: \(error.localizedDescription)
        """)
        await runCancelled(reason: "prerecordingStartFailed.\(clip.id)")
    }
}
```

Patch `playbackCompleted(handleID:)` with a new case before generated/filler:

```swift
case .prerecording(
    let id,
    let activeHandleID,
    let fileURL,
    let startedAt
)
    where activeHandleID == handleID:
    let elapsed = Date().timeIntervalSince(startedAt)
    prerecordingHasPlayed = true
    activeItem = .none
    print("""
    [TuringPlaybackRebuild] prerecording playback completed
      id: \(id)
      handleID: \(handleID.uuidString)
      file: \(fileURL.lastPathComponent)
      elapsedSeconds: \(String(format: "%.3f", elapsed))
      completionSource: actualPlaybackCompletion
    """)
    await reconcile(reason: "prerecordingCompleted")
```

Patch `activeItemLog`:

```swift
case .prerecording(let id, let handleID, let fileURL, let startedAt):
    let elapsed = Date().timeIntervalSince(startedAt)
    return "prerecording.\(id).\(fileURL.lastPathComponent).\(handleID.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
```

Required behavior:

```text
prerecording blocks generated speech until prerecording completion
voicePrompt can compute in parallel because compute is separate from playback
if generated speech is late after prerecording completion, existing filler/dead-air policy bridges
```

## 9. Expose Playback Bridge API For Prerecording

Patch private bridge in:

```text
Gravitas Plague/Gravitas Plague/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift
```

Add:

```swift
func enqueuePrerecording(
    id: String,
    fileURL: URL
) async {
    await coordinator.enqueuePrerecording(
        id: id,
        fileURL: fileURL
    )
}
```

This keeps one playback owner. Do not create a second coordinator for prerecording.

## 10. Add Orchestration Runner

New file:

```text
Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringPrerecordingSeededPromptRunner.swift
```

Code skeleton:

```swift
import Foundation
import TuringQwenNative

enum TuringPrerecordingSeededPromptRunner {
    static func runBigMikeCheckIn(
        seedStore: TuringConversationSeedStore
    ) async -> TuringNativeQwenRunResult {
        let prerecordingID = "prologue.walkie.bigMike.checkIn.001"
        let seedKey = "big_mike"

        do {
            let prerecordingStore = TuringPrerecordingStore()
            let prerecording = try prerecordingStore.descriptor(
                id: prerecordingID
            )
            let prerecordingAudioURL = try prerecordingStore.audioURL(
                for: prerecording
            )

            let service = TuringDialogueService()
            let voicePromptTask = Task.detached(priority: .userInitiated) {
                try await service.generateVoicePrompt(
                    VoicePromptRequest(
                        id: "voicePrompt.bigMike.afterCheckIn.001",
                        speaker: "Big Mike",
                        voiceID: prerecording.voiceID,
                        voiceVariantID: prerecording.voiceVariantID,
                        characterProfileID: "big_mike",
                        intent: prerecording.voicePromptIntent,
                        emotion: prerecording.defaultEmotion,
                        prerecordingTranscript: prerecording.transcript,
                        voicePromptSeedIntent: prerecording.summary
                    )
                )
            }

            return try await TuringNativeQwenHelloWorldCanary
                .runVoicePromptAfterPrerecording(
                    runID: "prologue.walkie.bigMike.checkIn.001",
                    prerecordingID: prerecording.prerecordingID,
                    prerecordingAudioURL: prerecordingAudioURL,
                    voicePromptTask: voicePromptTask,
                    seedStore: seedStore,
                    seedKey: seedKey
                )
        } catch {
            print("""
            [TuringPrerecordingSeed] failed
              prerecordingID: prologue.walkie.bigMike.checkIn.001
              error: \(error.localizedDescription)
            """)
            return .failed(error.localizedDescription)
        }
    }
}
```

## 11. Add Qwen Entry For One Playback Owner

Patch file:

```text
Gravitas Plague/Gravitas Plague/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift
```

Add a new method rather than trying to compose `runDialogueSegments`, because `runDialogueSegments` currently owns its own playback begin/wait cycle.

Code skeleton:

```swift
static func runVoicePromptAfterPrerecording(
    runID: String,
    prerecordingID: String,
    prerecordingAudioURL: URL,
    voicePromptTask: Task<TuringVoicePromptPlan, Error>,
    seedStore: TuringConversationSeedStore,
    seedKey: String
) async throws -> TuringNativeQwenRunResult {
    do {
        let gapAudio = await MainActor.run {
            TuringParallelPerfGapAudioBridge()
        }
        await gapAudio.beginRun(
            runID: runID,
            expectedSegmentCount: nil
        )
        await gapAudio.enqueuePrerecording(
            id: prerecordingID,
            fileURL: prerecordingAudioURL
        )

        let plan = try await voicePromptTask.value
        await seedStore.update(
            plan.conversationSeed,
            for: seedKey
        )

        guard plan.segments.isEmpty == false else {
            await gapAudio.qwenComputeAllFinished()
            await gapAudio.waitUntilPlaybackFinished()
            return .succeeded("Prerecording finished; voicePrompt produced no segments.")
        }

        let spokenSegments = plan.segments.map(\.text)
        let modelRoot = try locateBundledBaseCloneModel()
        let cloneProfile = try loadBundledBigMikeCloneProfile()
        let stagedRoot = try stageWritableModel(from: modelRoot)

        let freshPool = try TuringQwenNativeGenerationSchedulerFactory.makeFresh2Pool()
        try await freshPool.warmLoadExactlyRequestedInstances(
            modelRoot: stagedRoot,
            cloneProfile: cloneProfile,
            variantID: cloneProfile.defaultVariantID,
            performanceMode: .performance
        )
        let scheduler = TuringQwenNativeGenerationSchedulerFactory.makeFresh2Scheduler(
            instancePool: freshPool
        )

        let requests = makeParallelBaseCloneRequests(
            preset: .phase1FoundationVoiceScript,
            cloneProfile: cloneProfile,
            segments: spokenSegments,
            startingSegmentIndex: 0
        )

        _ = try await renderFreshBaseCloneRequests(
            requests,
            scheduler: scheduler,
            gapAudio: gapAudio,
            runID: runID,
            skipQwenSegmentFailures: true
        )

        await gapAudio.qwenComputeAllFinished()
        await gapAudio.waitUntilPlaybackFinished()
        await freshPool.unloadAll(reason: "voicePromptAfterPrerecording.\(runID)")
        return .succeeded("Finished \(runID)")
    } catch {
        print("""
        [TuringPrerecordingSeed] run failed
          runID: \(runID)
          error: \(error.localizedDescription)
        """)
        return .failed(error.localizedDescription)
    }
}
```

Important:

```text
If helper methods are private and inaccessible from this new method, keep this method inside TuringNativeQwenHelloWorldCanary.
Do not create a second playback coordinator.
Do not wait for voicePrompt before starting prerecording.
```

## 12. Conversation Prompt Uses Seed

Patch `TuringEpisodePickerView`:

Add state:

```swift
@State private var turingSeedStore = TuringConversationSeedStore()
```

The above may not work directly because actors are not `ObservableObject`. If SwiftUI rejects it, use:

```swift
private let turingSeedStore = TuringConversationSeedStore()
```

inside a reference wrapper:

```swift
@StateObject private var turingStoryState = TuringStoryDebugState()

@MainActor
final class TuringStoryDebugState: ObservableObject {
    let seedStore = TuringConversationSeedStore()
}
```

Patch `runBigMikeConversationNoBible` before building request:

```swift
Task.detached(priority: .userInitiated) {
    do {
        let seed = await turingStoryState.seedStore.seed(
            for: "big_mike"
        )
        let request = ConversationPromptNoBibleRequest(
            id: "story.picker.phase3light.conversation.001",
            speaker: "Big Mike",
            voiceID: "big_mike_base_clone_v1",
            voiceVariantID: "broadcast_reference_fast_01",
            characterProfileID: "big_mike",
            playerDictation: playerDictation,
            episodeStateForWordsOnly: "Rich is checking in with Big Mike during the early Gravitas Plague emergency. Big Mike is nearby, protective, tired, and trying to keep Rich calm and alive.",
            emotion: "protective, grounded, tired",
            prerecordingTranscript: nil,
            lastVoicePromptSeed: seed
        )

        let service = TuringDialogueService()
        let plan = try await service.generateConversationNoBible(
            request
        )
        ...
    } catch {
        ...
    }
}
```

If no seed exists, `seed` will be `.empty`.

## 13. Add Debug Button

Patch `TuringEpisodePickerView` inside debug button stack:

```swift
Button {
    runBigMikePrerecordingSeedTest()
} label: {
    HStack(spacing: 8) {
        if turingDialogueBusy {
            ProgressView()
                .controlSize(.small)
        }
        Text("Run Big Mike Check-In PR Seed")
    }
}
.buttonStyle(.bordered)
.disabled(qwenNativeRunningPreset != nil || turingDialogueBusy)
```

Add function:

```swift
private func runBigMikePrerecordingSeedTest() {
    guard qwenNativeRunningPreset == nil,
          turingDialogueBusy == false else {
        return
    }

    turingDialogueBusy = true
    qwenDebugStatus = "Running Big Mike prerecording seed test"
    radioStaticLeadIn.start(reason: "bigMikePrerecordingSeedStarted")

    Task.detached(priority: .userInitiated) {
        let result = await TuringPrerecordingSeededPromptRunner
            .runBigMikeCheckIn(
                seedStore: turingStoryState.seedStore
            )

        await MainActor.run {
            radioStaticLeadIn.stop(reason: "bigMikePrerecordingSeedFinished")
            turingDialogueBusy = false
            qwenDebugStatus = result.pickerStatus
        }
    }
}
```

If `turingStoryState` is `@MainActor`, capture the actor explicitly before `Task.detached`:

```swift
let seedStore = turingStoryState.seedStore
Task.detached(priority: .userInitiated) {
    let result = await TuringPrerecordingSeededPromptRunner
        .runBigMikeCheckIn(seedStore: seedStore)
    ...
}
```

## 14. Expected Logs

Good run:

```text
[TuringPlaybackRebuild] run started
[TuringPlaybackRebuild] prerecording queued
[TuringPlaybackRebuild] prerecording playback started
[TuringVoicePrompt] Foundation request started
[TuringFoundationRawResponse] BEGIN voicePrompt_characterIntent
[TuringVoicePrompt] gate passed
[TuringConversationSeed] updated
[TuringQwenFresh2] run started
[TuringPlaybackRebuild] prerecording playback completed
[TuringPlaybackRebuild] filler started
[TuringPlaybackRebuild] generated wav written
[TuringPlaybackRebuild] generated playback started
[TuringPlaybackRebuild] generated playback completed
```

Conversation after seed:

```text
[TuringConversationNoBible] Foundation request started
  seedStatus: present or empty
[TuringFoundationRawResponse] BEGIN conversationPrompt_playerTurn_noBible
[TuringConversationNoBible] gate passed
```

## 15. Audit Script To Add

New file:

```text
Scripts/audit_turing_prerecording_seeded_prompts.sh
```

Code:

```bash
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

reject_rg() {
  local pattern="$1"
  local path="$2"
  if rg -q "$pattern" "$ROOT/$path"; then
    echo "Unexpected pattern '$pattern' in $path" >&2
    exit 1
  fi
}

require_file "Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringConversationSeed.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringPrerecordingDescriptor.swift"
require_file "Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringPrerecordingSeededPromptRunner.swift"
require_file "Gravitas Plague/TuringResources/Turing/Prerecordings/prologue.walkie.bigMike.checkIn.001.json"

require_rg "conversationSeed" "Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringDialoguePayloads.swift"
require_rg "lastVoicePromptSeed" "Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringDialoguePayloads.swift"
require_rg "prerecordingTranscript" "Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringDialoguePayloads.swift"
require_rg "TuringConversationSeed.empty|\\.empty" "Gravitas Plague/Gravitas Plague/Turing/Dialog"

require_rg "conversationSeed" "Gravitas Plague/TuringResources/Turing/Prompts/voicePrompt_characterIntent.txt"
require_rg "lastVoicePromptSeed" "Gravitas Plague/TuringResources/Turing/Prompts/conversationPrompt_playerTurn_noBible.txt"
require_rg "prerecordingTranscript" "Gravitas Plague/TuringResources/Turing/Prompts/conversationPrompt_playerTurn_noBible.txt"

require_rg "case prerecording" "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringWalkieOneShotClipPlayer.swift"
require_rg "enqueuePrerecording" "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
require_rg "prerecording playback started" "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
require_rg "runVoicePromptAfterPrerecording" "Gravitas Plague/Gravitas Plague/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift"

require_rg "makeFresh2Pool" "Gravitas Plague/Gravitas Plague/Turing/Debug/TuringNativeQwenHelloWorldCanary.swift"
require_rg "freshInstanceCount.*2|exactFreshInstanceCount = 2" "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative"

reject_rg "Bible" "Gravitas Plague/TuringResources/Turing/Prompts/conversationPrompt_playerTurn_noBible.txt"
reject_rg "Focus" "Gravitas Plague/TuringResources/Turing/Prompts/conversationPrompt_playerTurn_noBible.txt"

echo "Turing prerecording seeded prompts audit passed."
```

## 16. Open Decisions For Rich

Need from Rich:

```text
1. Exact prerecording audio filename and format.
2. Confirm transcript is manual first.
3. Confirm seed key: big_mike vs walkieTalkie.bigMike.
4. Confirm whether voicePrompt should always return conversationSeed in MVP.
5. Confirm whether the generated voicePrompt follow-up should use broadcast_reference_fast_01 explicitly or current clone default.
```

Default recommendations:

```text
audio path: Turing/Audio/prerecordings/prologue_big_mike_checkin_001.wav
transcript: manual JSON field
seed key: big_mike
voicePrompt: returns segments plus conversationSeed
conversationPrompt: reads seed, but missing seed is empty and valid
voice variant: broadcast_reference_fast_01
```

