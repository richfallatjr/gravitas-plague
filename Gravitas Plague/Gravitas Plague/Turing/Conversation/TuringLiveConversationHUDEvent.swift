import Foundation

nonisolated struct TuringLiveConversationHUDEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case listeningStarted
        case partialTranscript(String)
        case questionSubmitted(String)
        case questionDisplayExpired
        case responsePlaybackStarted
        case responsePlaybackFinished
        case cancelled
        case failed(String)
    }

    let sessionID: UUID
    let turnID: UUID
    let generation: UInt64
    let surface: StoryInteractionSurfaceID
    let kind: Kind
}

@MainActor
protocol TuringLiveConversationHUDEventSink: AnyObject {
    func publishLiveConversationHUDEvent(
        _ event: TuringLiveConversationHUDEvent
    )
}
