import Foundation

@MainActor
final class TuringStoryLiveMicrophoneActionRouter {
    static let shared = TuringStoryLiveMicrophoneActionRouter()

    private let coordinator = TuringLiveConversationSessionCoordinator.shared

    private init() {}

    func microphoneHoldBegan(
        surface: StoryInteractionSurfaceID,
        source: String,
        dictation: TuringDictationCoordinator,
        eventSink: (any TuringStoryWalkieInteractionEventSink)?
    ) -> Bool {
        guard coordinator.canAcceptMicrophoneHold(surface: surface) else {
            return false
        }
        coordinator.microphoneHoldBegan(
            surface: surface,
            source: source,
            dictation: dictation,
            legacyEventSink: eventSink
        )
        return true
    }

    func microphoneHoldEnded(
        surface: StoryInteractionSurfaceID,
        source: String
    ) -> Bool {
        guard coordinator.ownsMicrophoneHold(surface: surface) else {
            return false
        }
        coordinator.microphoneHoldEnded(
            surface: surface,
            source: source
        )
        return true
    }
}
