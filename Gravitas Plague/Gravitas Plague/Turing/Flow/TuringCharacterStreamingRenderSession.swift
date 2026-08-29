import Foundation

protocol TuringCharacterStreamingRenderSession: Sendable {
    func begin(
        onStarted: @Sendable @escaping (Int) async -> Void,
        onFinished: @Sendable @escaping (
            Int,
            TuringComputeGapGeneratedAudio
        ) async throws -> Void,
        onSkipped: @Sendable @escaping (Int, String) async -> Void
    ) async throws

    func submit(_ stage: TuringCommittedSpeechStage) async throws
    func waitUntilPublished(throughExclusiveIndex: Int) async throws
    func sealInput(finalExpectedSegmentCount: Int) async
    func waitUntilPublished() async throws -> TuringCharacterRenderReport
    func finish(reason: String) async
    func cancel(reason: String) async
}

protocol TuringCharacterStreamingRenderSessionMaking: Sendable {
    func makeStreamingSession(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterStreamingRenderSession

    func makeStreamingSession(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String,
        continuity: TuringSpokenPresentationContinuity?
    ) -> any TuringCharacterStreamingRenderSession
}

extension TuringCharacterStreamingRenderSessionMaking {
    func makeStreamingSession(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String,
        continuity: TuringSpokenPresentationContinuity?
    ) -> any TuringCharacterStreamingRenderSession {
        makeStreamingSession(runtime: runtime, runID: runID)
    }
}
