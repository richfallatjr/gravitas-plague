import Foundation

nonisolated protocol MindEyeAuthoredPreparationStreaming: Sendable {
    func events() async -> AsyncStream<TuringAuthoredPresentationPreparationHint>
}

nonisolated struct MindEyeGlobalAuthoredPreparationSource:
    MindEyeAuthoredPreparationStreaming,
    Sendable
{
    let hub: TuringAuthoredPresentationPreparationHub

    init(hub: TuringAuthoredPresentationPreparationHub = .shared) {
        self.hub = hub
    }

    func events() async -> AsyncStream<TuringAuthoredPresentationPreparationHint> {
        await hub.events()
    }
}
