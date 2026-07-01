import Foundation

struct TuringVoiceScriptLongformRunner: Sendable {
    private let audiobookRunner: TuringPhase1AudiobookRunner

    init(
        audiobookRunner: TuringPhase1AudiobookRunner = TuringPhase1AudiobookRunner()
    ) {
        self.audiobookRunner = audiobookRunner
    }

    func audiobookPlan(
        request: TuringLongformVoiceScriptRequest
    ) async throws -> TuringPhase1AudiobookPlan {
        try await audiobookRunner.makePlan(request: request)
    }

    func makeSourcePlan(
        request: TuringLongformVoiceScriptRequest
    ) throws -> TuringAudiobookSourcePlan {
        try audiobookRunner.makeSourcePlan(request: request)
    }

    func prepareSection(
        _ section: TuringAudiobookSourceSection,
        in plan: TuringAudiobookSourcePlan,
        request: TuringLongformVoiceScriptRequest
    ) async throws -> TuringAudiobookSectionSegmentationResult {
        try await audiobookRunner.prepareSection(
            section,
            in: plan,
            request: request
        )
    }
}
