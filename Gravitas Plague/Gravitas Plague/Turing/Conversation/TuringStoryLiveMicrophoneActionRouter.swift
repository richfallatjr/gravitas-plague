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
        // RealityKit may deliver a second begin event for the same pinch. Once
        // the live coordinator owns that hold, consume duplicates here instead
        // of allowing the device's legacy conversation path to claim a lease.
        if coordinator.ownsMicrophoneHold(surface: surface) {
            return true
        }
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
