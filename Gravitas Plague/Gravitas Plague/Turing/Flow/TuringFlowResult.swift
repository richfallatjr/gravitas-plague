import Foundation

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
