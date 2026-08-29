import Foundation

nonisolated protocol MindEyeSpokenPresentationEventStreaming: Sendable {
    func events() async -> AsyncStream<TuringSpokenPresentationEvent>
}

nonisolated struct MindEyeGlobalSpokenPresentationEventSource:
    MindEyeSpokenPresentationEventStreaming,
    Sendable
{
    let hub: TuringSpokenPresentationHub

    init(hub: TuringSpokenPresentationHub = .shared) {
        self.hub = hub
    }

    func events() async -> AsyncStream<TuringSpokenPresentationEvent> {
        await hub.events()
    }
}
