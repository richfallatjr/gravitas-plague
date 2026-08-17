import Foundation

nonisolated enum TuringScriptPointCompletionBasis:
    String,
    Sendable,
    Equatable
{
    case authoredMediaPlaybackCompleted
    case interactiveGeneratedPlaybackCompleted
}

struct TuringFlowResult: Sendable, Equatable {
    enum Outcome: String, Sendable, Equatable {
        case succeeded
        case ignoredAnotherFlowActive
        case ignoredAlreadyCompleted
        case triggerMismatch
        case generatedPlanFailed
        case partialGeneratedFailure
        case generatedAudioFailed
        case playbackFailed
        case configurationFailed
        case cancelled
    }

    let outcome: Outcome
    let identity: TuringFlowIdentity?
    let expectedGeneratedSegmentCount: Int
    let completedGeneratedSegmentCount: Int
    let skippedGeneratedSegmentIndices: [Int]
    let message: String
    let experienceMode: StoryExperienceMode
    let completionBasis: TuringScriptPointCompletionBasis

    init(
        outcome: Outcome,
        identity: TuringFlowIdentity?,
        expectedGeneratedSegmentCount: Int,
        completedGeneratedSegmentCount: Int,
        skippedGeneratedSegmentIndices: [Int],
        message: String,
        experienceMode: StoryExperienceMode = .interactive,
        completionBasis: TuringScriptPointCompletionBasis =
            .interactiveGeneratedPlaybackCompleted
    ) {
        self.outcome = outcome
        self.identity = identity
        self.expectedGeneratedSegmentCount = expectedGeneratedSegmentCount
        self.completedGeneratedSegmentCount = completedGeneratedSegmentCount
        self.skippedGeneratedSegmentIndices = skippedGeneratedSegmentIndices
        self.message = message
        self.experienceMode = experienceMode
        self.completionBasis = completionBasis
    }

    var succeeded: Bool {
        outcome == .succeeded
    }

    static func ignored(
        _ outcome: Outcome,
        message: String
    ) -> TuringFlowResult {
        TuringFlowResult(
            outcome: outcome,
            identity: nil,
            expectedGeneratedSegmentCount: 0,
            completedGeneratedSegmentCount: 0,
            skippedGeneratedSegmentIndices: [],
            message: message
        )
    }

    var voiceRunResult: TuringVoiceRunResult {
        if succeeded {
            return .succeeded(message)
        }
        return .failed(message)
    }
}
