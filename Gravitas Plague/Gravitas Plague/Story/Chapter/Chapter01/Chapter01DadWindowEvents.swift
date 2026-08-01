import Foundation

struct Chapter01DadExitWalkStartedEvent: Sendable {
    let chapterRunID: UUID
    let storyTransitionLease: StoryInteractionLease
    let locomotionActuallyStarted: Bool
}

struct Chapter01DadRuntimeReleaseReport: Sendable, Equatable {
    let chapterRunID: UUID
    let heavyRuntimeReleased: Bool
    let preparedClipCountReleased: Int
    let collisionCountReleased: Int
    let audioControllerCountReleased: Int
}

struct Chapter01DadRuntimeReleasedEvent: Sendable {
    let chapterRunID: UUID
    let releaseReport: Chapter01DadRuntimeReleaseReport
}

struct Chapter01DadWindowFailureEvent: Sendable {
    let chapterRunID: UUID
    let message: String
}

@MainActor
protocol Chapter01DadWindowCompletionSink: AnyObject {
    func dadExitWalkStarted(
        _ event: Chapter01DadExitWalkStartedEvent
    ) async throws

    func dadRuntimeReleased(
        _ event: Chapter01DadRuntimeReleasedEvent
    ) async

    func dadWindowFailed(
        _ event: Chapter01DadWindowFailureEvent
    ) async
}

struct Chapter01DadWindowRequest {
    let chapterRunID: UUID
    let storyTransitionLease: StoryInteractionLease
    let completionSink: any Chapter01DadWindowCompletionSink
}
