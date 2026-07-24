import Foundation
import XCTest
@testable import Gravitas_Plague

@MainActor
final class TuringStagedSpeechRunCoordinatorTests: XCTestCase {
    func testPromptVoiceFailurePreservesPublishedScriptVoiceCount()
        async throws {
        let recorder = TuringFlowTestEventRecorder()
        let route: TuringVoiceOutputContext = .walkieSpatial
        let character = TuringFlowTestFixtures.character(
            id: "big_mike",
            voiceID: "big_mike",
            outputRoute: route
        )
        let prerecording = TuringFlowTestFixtures.prerecording(
            id: "test.pr",
            characterID: character.characterID,
            voiceID: character.voiceID
        )
        let scriptStage = TuringFlowGenerationPipelineDescriptor.Stage(
            stageID: "headlineReading",
            kind: .voiceScriptLongform,
            sourceResourcePath: "unused-by-stub.txt",
            voicePromptID: nil,
            defaultEmotion: "measured",
            contextSource: .init(
                kind: .prerecordingTranscript,
                stageID: nil
            )
        )
        let promptStage = TuringFlowGenerationPipelineDescriptor.Stage(
            stageID: "promptVoice",
            kind: .voicePrompt,
            sourceResourcePath: nil,
            voicePromptID: "test.prompt",
            defaultEmotion: "controlled",
            contextSource: .init(
                kind: .stageSourceTranscript,
                stageID: scriptStage.stageID
            )
        )
        let pipeline = TuringFlowGenerationPipelineDescriptor(
            schemaVersion: 1,
            radioBridgeMode: .bigMikeStaticAndFiller,
            stages: [scriptStage, promptStage]
        )
        let descriptor = TuringFlowDescriptor(
            schemaVersion: 2,
            scriptPointID: "test.scriptPoint05",
            trigger: .init(kind: .manualDebug, delaySeconds: 0),
            transmission: .init(
                prerecordingID: prerecording.prerecordingID,
                voicePromptID: nil,
                characterID: character.characterID,
                conversationKey: "test.conversation",
                outputRoute: route,
                computeStart: .beforePrerecording,
                fillerMode: .continuousFromPrerecordingToGenerated,
                commSFX: .init(
                    openBeforePrerecording: false,
                    sendAfterGenerated: false,
                    sendingLeadInAfterGeneratedSeconds: nil
                ),
                fixedLeadInSeconds: 10,
                generationPipeline: pipeline
            ),
            progression: .init(
                nextScriptPointID: nil,
                automaticAdvance: false,
                interactionGateAfterCompletion: .microphone
            )
        )
        let identity = TuringFlowIdentity(
            scriptPointID: descriptor.scriptPointID,
            characterID: character.characterID,
            prerecordingID: prerecording.prerecordingID,
            voicePromptID: "test.prompt"
        )
        let playback = StubFlowPlayback(
            recorder: recorder,
            autoCompletePrerecording: true
        )
        await playback.beginRun(
            runID: identity.playbackRunID,
            expectedSegmentCount: nil
        )
        await playback.enqueuePrerecording(
            id: prerecording.prerecordingID,
            fileURL: URL(fileURLWithPath: "/tmp/test-pr.wav")
        )

        let coordinator = TuringStagedSpeechRunCoordinator(
            voiceScriptExecutor: StubStagedSpeechExecutor(
                kind: .voiceScriptLongform,
                recorder: recorder,
                segments: [
                    TuringSpeechSegment(
                        text: "Headline segment zero.",
                        emotion: "measured"
                    ),
                    TuringSpeechSegment(
                        text: "Headline segment one.",
                        emotion: "measured"
                    )
                ],
                sourceTranscript: "Exact normalized headline source.",
                failure: nil
            ),
            promptVoiceExecutor: StubStagedSpeechExecutor(
                kind: .voicePrompt,
                recorder: recorder,
                segments: [],
                sourceTranscript: nil,
                failure: "promptVoice guardrails"
            ),
            rendererFactory: StubStagedRenderSessionFactory(
                recorder: recorder
            ),
            seedStore: TuringConversationSeedStore()
        )

        let report = try await coordinator.run(
            descriptor: descriptor,
            pipeline: pipeline,
            character: character,
            prerecording: prerecording,
            playback: playback,
            identity: identity
        )

        XCTAssertEqual(report.finalExpectedSegmentCount, 2)
        XCTAssertEqual(report.completedPlaybackCount, 2)
        XCTAssertEqual(report.committedStages.count, 1)
        XCTAssertEqual(report.committedStages[0].globalRange, 0..<2)
        XCTAssertEqual(report.failedStages.count, 1)
        XCTAssertEqual(report.failedStages[0].stageID, "promptVoice")

        let events = await recorder.snapshot()
        assertOrdered(
            events,
            [
                "stage.voiceScriptLongform.started",
                "render.0.started",
                "playback.segment.0.published",
                "generated.0.started",
                "render.1.started",
                "playback.segment.1.published",
                "generated.1.started",
                "stage.voicePrompt.started",
                "playback.inputSealed.2",
                "playback.finished"
            ]
        )
        XCTAssertFalse(events.contains("playback.inputSealed.0"))
    }

    private func assertOrdered(
        _ events: [String],
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = 0
        for event in expected {
            guard let index = events[cursor...].firstIndex(of: event) else {
                XCTFail(
                    "Missing ordered event \(event). Events: \(events)",
                    file: file,
                    line: line
                )
                return
            }
            cursor = events.index(after: index)
        }
    }
}

private struct StubStagedSpeechExecutor: TuringSpeechStageExecuting {
    let kind: TuringFlowGenerationPipelineDescriptor.Stage.Kind
    let recorder: TuringFlowTestEventRecorder
    let segments: [TuringSpeechSegment]
    let sourceTranscript: String?
    let failure: String?

    func execute(
        stage: TuringFlowGenerationPipelineDescriptor.Stage,
        context: TuringSpeechStageContext,
        onPreparedBatch: @Sendable (TuringPreparedSpeechBatch) async throws -> Void
    ) async throws -> TuringSpeechStageExecutionResult {
        await recorder.record("stage.\(kind.rawValue).started")
        if let failure {
            throw NSError(
                domain: "TuringStagedSpeechTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: failure]
            )
        }
        try await onPreparedBatch(
            TuringPreparedSpeechBatch(
                stageID: stage.stageID,
                batchID: "\(stage.stageID).batch0",
                isFinalBatchForStage: true,
                segments: segments
            )
        )
        return TuringSpeechStageExecutionResult(
            normalizedSourceTranscript: sourceTranscript,
            promptVoiceSeed: nil,
            failedBatchDescriptions: []
        )
    }
}

private struct StubStagedRenderSessionFactory:
    TuringCharacterStreamingRenderSessionMaking
{
    let recorder: TuringFlowTestEventRecorder

    func makeStreamingSession(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterStreamingRenderSession {
        StubStagedRenderSession(recorder: recorder)
    }
}

private actor StubStagedRenderSession:
    TuringCharacterStreamingRenderSession
{
    let recorder: TuringFlowTestEventRecorder
    private var onStarted: (@Sendable (Int) async -> Void)?
    private var onFinished: (@Sendable (
        Int,
        TuringComputeGapGeneratedAudio
    ) async throws -> Void)?
    private var onSkipped: (@Sendable (Int, String) async -> Void)?
    private var successfulIndices = Set<Int>()
    private var expectedSegmentCount = 0

    init(recorder: TuringFlowTestEventRecorder) {
        self.recorder = recorder
    }

    func begin(
        onStarted: @Sendable @escaping (Int) async -> Void,
        onFinished: @Sendable @escaping (
            Int,
            TuringComputeGapGeneratedAudio
        ) async throws -> Void,
        onSkipped: @Sendable @escaping (Int, String) async -> Void
    ) async throws {
        self.onStarted = onStarted
        self.onFinished = onFinished
        self.onSkipped = onSkipped
        await recorder.record("renderSession.started")
    }

    func submit(_ stage: TuringCommittedSpeechStage) async throws {
        guard let onStarted, let onFinished else {
            throw TuringRuntimeError.invalidConfig(
                "Stub streaming render session was not started."
            )
        }
        for index in stage.globalRange {
            await recorder.record("render.\(index).started")
            await onStarted(index)
            try await onFinished(
                index,
                TuringComputeGapGeneratedAudio(
                    segmentIndex: index,
                    samples: [0.1],
                    sampleRate: 24_000,
                    channelCount: 1
                )
            )
            successfulIndices.insert(index)
        }
    }

    func waitUntilPublished(throughExclusiveIndex: Int) async throws {
        let unresolved = (0..<throughExclusiveIndex).filter {
            successfulIndices.contains($0) == false
        }
        guard unresolved.isEmpty else {
            throw TuringRuntimeError.invalidConfig(
                "Stub unresolved indexes: \(unresolved)"
            )
        }
    }

    func sealInput(finalExpectedSegmentCount: Int) async {
        expectedSegmentCount = finalExpectedSegmentCount
    }

    func waitUntilPublished() async throws -> TuringCharacterRenderReport {
        return TuringCharacterRenderReport(
            expectedSegmentCount: expectedSegmentCount,
            successfulSegmentIndices: successfulIndices,
            skippedSegmentReasons: [:]
        )
    }

    func finish(reason: String) async {
        await recorder.record("renderSession.finished")
    }

    func cancel(reason: String) async {
        await recorder.record("renderSession.cancelled")
    }
}
