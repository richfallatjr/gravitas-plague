import Foundation

nonisolated struct TuringAuthoredPresentationPreparationHint:
    Sendable,
    Equatable,
    Hashable
{
    let run: TuringSpokenPresentationRunIdentity
    let prerecordingID: String
    let role: TuringAuthoredMediaItem.Role
    let speakerCharacterID: TuringConversationCharacterID
    let interactionSurface: StoryInteractionSurfaceID

    var key: String {
        [
            run.playbackRunID,
            run.flowInstanceID.uuidString.lowercased(),
            prerecordingID,
            role.rawValue
        ].joined(separator: "|")
    }
}

actor TuringAuthoredPresentationPreparationHub {
    static let shared = TuringAuthoredPresentationPreparationHub()
    private var continuations: [
        UUID: AsyncStream<TuringAuthoredPresentationPreparationHint>.Continuation
    ] = [:]

    func events() -> AsyncStream<TuringAuthoredPresentationPreparationHint> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    func publish(_ hint: TuringAuthoredPresentationPreparationHint) {
        for continuation in continuations.values { continuation.yield(hint) }
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
