import Foundation
import XCTest
@testable import Gravitas_Plague

actor TuringFlowTestEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }

    func firstIndex(of event: String) -> Int? {
        events.firstIndex(of: event)
    }

    func waitFor(
        _ event: String,
        attempts: Int = 2_000
    ) async throws {
        for _ in 0..<attempts {
            if events.contains(event) {
                return
            }
            await Task.yield()
        }

        throw NSError(
            domain: "TuringFlowTest",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for event \(event). Events: \(events)"
            ]
        )
    }
}

struct StubFlowDescriptorStore:
    TuringFlowDescriptorLoading,
    Sendable
{
    let descriptors: [String: TuringFlowDescriptor]

    func require(
        _ scriptPointID: String
    ) throws -> TuringFlowDescriptor {
        guard let descriptor =
                descriptors[scriptPointID] else {
            throw TuringRuntimeError.invalidConfig(
                "Missing test descriptor \(scriptPointID)."
            )
        }
        return descriptor
    }
}

struct StubPrerecordingStore:
    TuringPrerecordingLoading,
    Sendable
{
    let descriptors:
        [String: TuringPrerecordingDescriptor]

    func descriptor(
        id: String
    ) throws -> TuringPrerecordingDescriptor {
        guard let descriptor =
                descriptors[id] else {
            throw TuringRuntimeError.invalidConfig(
                "Missing test prerecording \(id)."
            )
        }
        return descriptor
    }

    func audioURL(
        for descriptor:
            TuringPrerecordingDescriptor
    ) throws -> URL {
        URL(
            fileURLWithPath:
                "/tmp/\(descriptor.audioFile)"
        )
    }
}

struct StubVoicePromptStore:
    TuringVoicePromptTriggerLoading,
    Sendable
{
    let descriptors:
        [String: TuringVoicePromptTriggerDescriptor]

    func descriptor(
        id: String
    ) throws -> TuringVoicePromptTriggerDescriptor {
        guard let descriptor =
                descriptors[id] else {
            throw TuringRuntimeError.invalidConfig(
                "Missing test voicePrompt \(id)."
            )
        }
        return descriptor
    }
}

struct StubCharacterRuntimeStore:
    TuringCharacterRuntimeProviding,
    Sendable
{
    let definitions:
        [String: TuringCharacterRuntimeDefinition]

    func require(
        _ characterID: String
    ) throws -> TuringCharacterRuntimeDefinition {
        guard let definition =
                definitions[characterID] else {
            throw TuringRuntimeError.invalidConfig(
                "Missing test character \(characterID)."
            )
        }
        return definition
    }
}

actor ControlledVoicePromptService:
    TuringFlowVoicePromptGenerating
{
    enum Behavior: Sendable {
        case immediate(TuringVoicePromptPlan)
        case delayed(TuringVoicePromptPlan)
        case failed(String)
    }

    private let recorder:
        TuringFlowTestEventRecorder
    private let behavior: Behavior

    private var released = false
    private var continuations:
        [CheckedContinuation<Void, Never>] = []

    init(
        recorder: TuringFlowTestEventRecorder,
        behavior: Behavior
    ) {
        self.recorder = recorder
        self.behavior = behavior
    }

    func generateVoicePrompt(
        _ request: VoicePromptRequest
    ) async throws -> TuringVoicePromptPlan {
        await recorder.record("foundation.started")

        switch behavior {
        case .immediate(let plan):
            await recorder.record(
                "foundation.completed"
            )
            return plan

        case .delayed(let plan):
            if released == false {
                await withCheckedContinuation {
                    continuation in
                    continuations.append(
                        continuation
                    )
                }
            }
            await recorder.record(
                "foundation.completed"
            )
            return plan

        case .failed(let message):
            throw NSError(
                domain: "TuringFlowTest",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        message
                ]
            )
        }
    }

    func release() {
        released = true
        let current = continuations
        continuations.removeAll(
            keepingCapacity: false
        )
        current.forEach {
            $0.resume()
        }
    }
}

struct StubCharacterRendererFactory:
    TuringCharacterRendererMaking,
    Sendable
{
    let recorder:
        TuringFlowTestEventRecorder
    let completionOrder: [Int]
    let failureMessage: String?

    func make(
        runtime:
            TuringCharacterRuntimeDefinition
    ) -> any TuringCharacterRendering {
        StubCharacterRenderer(
            recorder: recorder,
            completionOrder:
                completionOrder,
            failureMessage:
                failureMessage
        )
    }
}

actor StubCharacterRenderer:
    TuringCharacterRendering
{
    let recorder:
        TuringFlowTestEventRecorder
    let completionOrder: [Int]
    let failureMessage: String?

    func render(
        segments: [TuringSpeechSegment],
        runID: String,
        onStarted:
            @Sendable @escaping (Int) async -> Void,
        onFinished:
            @Sendable @escaping (
                Int,
                TuringComputeGapGeneratedAudio
            ) async -> Void,
        onSkipped:
            @Sendable @escaping (
                Int,
                String
            ) async -> Void
    ) async throws -> TuringCharacterRenderReport {
        await recorder.record("qwen.started")

        if let failureMessage {
            throw NSError(
                domain: "TuringFlowTest",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        failureMessage
                ]
            )
        }

        var successful = Set<Int>()

        for index in completionOrder {
            guard segments.indices.contains(index) else {
                continue
            }

            await onStarted(index)
            await recorder.record(
                "qwen.segment.\(index).started"
            )

            let audio =
                TuringComputeGapGeneratedAudio(
                    segmentIndex: index,
                    samples: [
                        Float(index) + 0.1
                    ],
                    sampleRate: 24_000,
                    channelCount: 1
                )
            await onFinished(
                index,
                audio
            )
            successful.insert(index)
            await recorder.record(
                "qwen.segment.\(index).finished"
            )
        }

        await recorder.record("qwen.finished")

        return TuringCharacterRenderReport(
            expectedSegmentCount:
                segments.count,
            successfulSegmentIndices:
                successful,
            skippedSegmentReasons: [:]
        )
    }
}

struct StubFlowRouteResolver:
    TuringFlowRouteResolving,
    Sendable
{
    let route: StubFlowRoute

    func require(
        _ outputRoute: TuringVoiceOutputContext
    ) async throws -> any TuringFlowRouteRuntime {
        route
    }
}

@MainActor
final class StubFlowRoute:
    TuringFlowRouteRuntime,
    @unchecked Sendable
{
    let outputRoute:
        TuringVoiceOutputContext
    let recorder:
        TuringFlowTestEventRecorder
    let autoCompletePrerecording: Bool

    private(set) var latestPlayback:
        StubFlowPlayback?

    init(
        outputRoute:
            TuringVoiceOutputContext,
        recorder:
            TuringFlowTestEventRecorder,
        autoCompletePrerecording: Bool =
            false
    ) {
        self.outputRoute = outputRoute
        self.recorder = recorder
        self.autoCompletePrerecording =
            autoCompletePrerecording
    }

    func validate(
        descriptor: TuringFlowDescriptor,
        character:
            TuringCharacterRuntimeDefinition
    ) throws {
    }

    func makePlayback(
        descriptor: TuringFlowDescriptor,
        character:
            TuringCharacterRuntimeDefinition,
        identity: TuringFlowIdentity
    ) throws -> any TuringFlowPlaybackControlling {
        let playback = StubFlowPlayback(
            recorder: recorder,
            autoCompletePrerecording:
                autoCompletePrerecording
        )
        latestPlayback = playback
        return playback
    }

    func runFixedLeadInIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async {
        if descriptor.transmission
            .fixedLeadInSeconds != nil {
            await recorder.record(
                "route.fixedLeadIn"
            )
        }
    }

    func playOpenIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        if descriptor.transmission.commSFX
            .openBeforePrerecording {
            await recorder.record(
                "route.open"
            )
        }
    }

    func playSendIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        if descriptor.transmission.commSFX
            .sendAfterGenerated {
            await recorder.record(
                "route.send"
            )
        }
    }

    func finish(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        succeeded: Bool
    ) async {
        await recorder.record(
            "route.finish.\(succeeded)"
        )
    }
}

@MainActor
final class StubFlowPlayback:
    TuringFlowPlaybackControlling,
    @unchecked Sendable
{
    private let recorder:
        TuringFlowTestEventRecorder
    private let autoCompletePrerecording:
        Bool

    private var identity:
        TuringFlowIdentity?
    private var expectedCount: Int?
    private var prerecordingCompleted =
        false
    private var allComputeFinished =
        false
    private var pending:
        [Int: TuringComputeGapGeneratedAudio] = [:]
    private var skipped = Set<Int>()
    private var nextIndex = 0
    private var completedCount = 0
    private var finished = false
    private var fillerPlayed = false
    private var waiters:
        [CheckedContinuation<Void, Never>] = []

    init(
        recorder:
            TuringFlowTestEventRecorder,
        autoCompletePrerecording:
            Bool
    ) {
        self.recorder = recorder
        self.autoCompletePrerecording =
            autoCompletePrerecording
    }

    func configureFlowIdentity(
        _ identity: TuringFlowIdentity
    ) {
        self.identity = identity
    }

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async {
        expectedCount =
            expectedSegmentCount
        await recorder.record(
            "playback.begin"
        )
    }

    func expectPrerecordingBeforeGenerated() async {
        await recorder.record(
            "playback.prerecordingExpected"
        )
    }

    func enqueuePrerecording(
        id: String,
        fileURL: URL
    ) async {
        await recorder.record(
            "pr.enqueued"
        )
        await recorder.record(
            "pr.started"
        )

        if autoCompletePrerecording {
            await completePrerecording()
        }
    }

    func setExpectedGeneratedSegmentCount(
        _ count: Int
    ) async {
        expectedCount = count
        await recorder.record(
            "playback.expected.\(count)"
        )
        await reconcile()
    }

    func qwenComputeStarted(
        segmentIndex: Int
    ) async {
        await recorder.record(
            "playback.compute.\(segmentIndex).started"
        )
    }

    func qwenComputeFinished(
        segmentIndex: Int,
        audio:
            TuringComputeGapGeneratedAudio
    ) async {
        pending[segmentIndex] = audio
        await recorder.record(
            "playback.segment.\(segmentIndex).published"
        )
        await reconcile()
    }

    func qwenComputeSkipped(
        segmentIndex: Int,
        reason: String
    ) async {
        skipped.insert(segmentIndex)
        await reconcile()
    }

    func qwenComputeAllFinished() async {
        allComputeFinished = true
        await recorder.record(
            "playback.compute.allFinished"
        )
        await reconcile()
    }

    func sealGeneratedInput(
        finalExpectedSegmentCount: Int
    ) async {
        expectedCount = finalExpectedSegmentCount
        allComputeFinished = true
        await recorder.record(
            "playback.inputSealed.\(finalExpectedSegmentCount)"
        )
        await reconcile()
    }

    func qwenComputeFailed(
        expectedSegmentCount: Int,
        reason: String
    ) async {
        expectedCount =
            expectedSegmentCount
        for index in nextIndex..<expectedSegmentCount
        where pending[index] == nil {
            skipped.insert(index)
        }
        allComputeFinished = true
        await recorder.record(
            "playback.compute.failed"
        )
        await reconcile()
    }

    func waitUntilPlaybackFinished() async {
        if finished {
            return
        }

        await withCheckedContinuation {
            continuation in
            waiters.append(
                continuation
            )
        }
    }

    func completedGeneratedSegmentCount()
        -> Int {
        completedCount
    }

    func runCancelled(reason: String) async {
        await recorder.record(
            "playback.cancelled"
        )
        await finish()
    }

    func completePrerecording() async {
        guard prerecordingCompleted == false else {
            return
        }

        prerecordingCompleted = true
        await recorder.record(
            "pr.completed"
        )

        if pending[0] == nil,
           allComputeFinished == false,
           fillerPlayed == false {
            fillerPlayed = true
            await recorder.record(
                "filler.started"
            )
            await recorder.record(
                "filler.completed"
            )
        }

        await reconcile()
    }

    private func reconcile() async {
        guard finished == false,
              prerecordingCompleted else {
            return
        }

        while skipped.remove(nextIndex) != nil {
            nextIndex += 1
        }

        while pending.removeValue(
            forKey: nextIndex
        ) != nil {
            await recorder.record(
                "generated.\(nextIndex).started"
            )
            await recorder.record(
                "generated.\(nextIndex).completed"
            )
            completedCount += 1
            nextIndex += 1

            while skipped.remove(nextIndex) != nil {
                nextIndex += 1
            }
        }

        if allComputeFinished,
           let expectedCount,
           nextIndex >= expectedCount {
            await finish()
        }
    }

    private func finish() async {
        guard finished == false else {
            return
        }

        finished = true
        await recorder.record(
            "playback.finished"
        )

        let current = waiters
        waiters.removeAll(
            keepingCapacity: false
        )
        current.forEach {
            $0.resume()
        }
    }
}

enum TuringFlowTestFixtures {
    static func character(
        id: String,
        voiceID: String,
        outputRoute:
            TuringVoiceOutputContext
    ) -> TuringCharacterRuntimeDefinition {
        TuringCharacterRuntimeDefinition(
            characterID: id,
            displayName: id,
            voiceID: voiceID,
            cloneProfileResourcePath:
                "Turing/Voices/\(voiceID).qwenclone",
            allowedOutputRoutes: [
                outputRoute
            ],
            outputProcessing: .init(
                playbackRate: 0.85
            ),
            qwen: .init(
                maxNewRows: 160,
                useExactReferenceRowCount:
                    true,
                referenceWindowStrategy:
                    "full",
                skipSegmentFailures: true
            ),
            audio: .init(
                generatedGainDB: 0,
                prerecordingGainDB: -6,
                fillerGainDB: -6,
                fillerDirectoryCandidates: [
                    "test-filler"
                ],
                fillerExtensions: [
                    "wav"
                ]
            )
        )
    }

    static func prerecording(
        id: String,
        characterID: String,
        voiceID: String
    ) -> TuringPrerecordingDescriptor {
        TuringPrerecordingDescriptor(
            schemaVersion: 1,
            prerecordingID: id,
            speaker: characterID,
            voiceID: voiceID,
            voiceVariantID: nil,
            audioFile: "\(id).wav",
            transcriptMode: .manual,
            transcript:
                "This authored line already played.",
            summary: "Test summary.",
            voicePromptIntent:
                "Continue after the PR.",
            defaultEmotion: "controlled"
        )
    }

    static func prompt(
        id: String,
        characterID: String,
        voiceID: String,
        outputRoute:
            TuringVoiceOutputContext,
        conversationKey: String
    ) -> TuringVoicePromptTriggerDescriptor {
        TuringVoicePromptTriggerDescriptor(
            schemaVersion: 1,
            voicePromptID: id,
            speakerID: characterID,
            voiceID: voiceID,
            characterProfileID:
                characterID,
            outputContext:
                outputRoute,
            conversationKey:
                conversationKey,
            intent:
                "Continue after the PR.",
            emotion: "controlled"
        )
    }

    static func descriptor(
        id: String,
        prerecordingID: String,
        voicePromptID: String,
        characterID: String,
        outputRoute:
            TuringVoiceOutputContext,
        conversationKey: String,
        open: Bool = false,
        send: Bool = false,
        fixedLeadIn: Double? = nil,
        gate:
            TuringFlowDescriptor.Progression
                .InteractionGate =
                    .microphone
    ) -> TuringFlowDescriptor {
        TuringFlowDescriptor(
            schemaVersion: 2,
            scriptPointID: id,
            trigger: .init(
                kind: .manualDebug,
                delaySeconds: 0
            ),
            transmission: .init(
                prerecordingID:
                    prerecordingID,
                voicePromptID:
                    voicePromptID,
                characterID:
                    characterID,
                conversationKey:
                    conversationKey,
                outputRoute:
                    outputRoute,
                computeStart:
                    .withPrerecording,
                fillerMode:
                    .continuousFromPrerecordingToGenerated,
                commSFX: .init(
                    openBeforePrerecording:
                        open,
                    sendAfterGenerated:
                        send,
                    sendingLeadInAfterGeneratedSeconds:
                        nil
                ),
                fixedLeadInSeconds:
                    fixedLeadIn,
                generationPipeline:
                    nil
            ),
            progression: .init(
                nextScriptPointID: nil,
                automaticAdvance: false,
                interactionGateAfterCompletion:
                    gate
            )
        )
    }

    static var plan:
        TuringVoicePromptPlan {
        TuringVoicePromptPlan(
            schemaVersion: 1,
            segments: [
                TuringSpeechSegment(
                    text: "Segment zero.",
                    emotion: "controlled"
                ),
                TuringSpeechSegment(
                    text: "Segment one.",
                    emotion: "controlled"
                )
            ],
            conversationSeed:
                TuringConversationSeed(
                    seedID: "test.seed",
                    summary: "Test.",
                    currentAttitude:
                        "Controlled.",
                    recentFacts: [
                        "Test fact."
                    ],
                    openThread:
                        "Continue."
                )
        )
    }
}
