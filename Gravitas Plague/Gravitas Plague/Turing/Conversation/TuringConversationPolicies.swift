import Foundation

nonisolated enum TuringConversationLeasePolicy: Sendable {
    case ownedByConversation
    case borrowedFromAuthoredFlow(
        parentFlowInstanceID: UUID,
        parentLeaseID: UUID
    )
}

nonisolated enum TuringConversationProgressionPolicy: Sendable {
    case existingInteractiveBehavior
    case neverAdvanceStory
}

nonisolated enum TuringConversationCompletionPresentation: Sendable {
    case restoreStableMicrophone
    case callerOwned
}

nonisolated enum TuringConversationLifecycleEvent: Sendable, Equatable {
    case foundationStarted(turnID: UUID)
    case foundationCompleted(turnID: UUID, segmentCount: Int)
    case segmentPublished(turnID: UUID, index: Int)
    case segmentZeroPrepared(turnID: UUID)
    case allTTSComputeFinished(
        turnID: UUID,
        expectedCount: Int,
        skippedIndices: [Int]
    )
    case responsePlaybackOwnerReady(turnID: UUID, playbackRunID: String)
    case responsePlaybackStarted(turnID: UUID, handle: TuringAudioPlaybackHandle)
    case responsePlaybackCompleted(turnID: UUID)
    case failed(turnID: UUID, stage: String, message: String)
}

@MainActor
protocol TuringConversationLifecycleSink: Sendable {
    func emit(_ event: TuringConversationLifecycleEvent) async

    func responsePlaybackOwnerReady(
        turnID: UUID,
        playback: any TuringFlowPlaybackControlling
    ) async
}

extension TuringConversationLifecycleSink {
    func responsePlaybackOwnerReady(
        turnID _: UUID,
        playback _: any TuringFlowPlaybackControlling
    ) async {}
}

actor TuringLiveConversationComputeAdmission {
    struct Token: Sendable, Equatable, Hashable {
        let id: UUID
        let sessionID: UUID
        let turnID: UUID
    }

    static let shared = TuringLiveConversationComputeAdmission()
    private var active: Token?

    func reserve(sessionID: UUID, turnID: UUID) throws -> Token {
        guard active == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Another live conversation response is computing."
            )
        }
        let token = Token(id: UUID(), sessionID: sessionID, turnID: turnID)
        active = token
        return token
    }

    func release(_ token: Token, reason: String) {
        guard active == token else { return }
        active = nil
        print("[TuringLiveConversation] compute admission released turnID=\(token.turnID.uuidString) reason=\(reason)")
    }

    func reset(reason: String) {
        active = nil
        print("[TuringLiveConversation] compute admission reset reason=\(reason)")
    }

    func activeReservationCount() -> Int {
        active == nil ? 0 : 1
    }
}
