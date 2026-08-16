import Foundation

nonisolated struct Chapter03LightTunnelRequest: Sendable {
    let chapterRunID: UUID
    let interactionLease: StoryInteractionLease
    let blackoutRequestID: UUID
    let resolvedDefinition: Chapter03LightTunnelResolvedDefinition
}

nonisolated struct Chapter03LightTunnelCompletedEvent: Sendable, Equatable {
    let chapterRunID: UUID
    let completionEventID: UUID
    let musicActuallyCompleted: Bool
    let angelPrerecordingWasConfigured: Bool
    let angelPrerecordingWasStarted: Bool
    let angelPrerecordingActuallyCompleted: Bool
    let interactionLease: StoryInteractionLease
    let blackoutRequestID: UUID
}
