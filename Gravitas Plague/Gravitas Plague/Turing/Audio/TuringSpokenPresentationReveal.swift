import Foundation

nonisolated struct TuringSpokenPresentationRevealRequest: Sendable {
    let id: UUID
    let run: TuringSpokenPresentationRunIdentity
    let speakerCharacterID: TuringConversationCharacterID
    let interactionSurface: StoryInteractionSurfaceID
    let source: TuringSpokenPresentationSource
    let generatedSpeechFrameTrack: TuringGeneratedSpeechFrameTrack?

    var key: String {
        [
            run.playbackRunID,
            run.flowInstanceID.uuidString.lowercased(),
            source.mediaIdentity
        ].joined(separator: "|")
    }

    func previewContext(
        clockOrigin: ContinuousClock.Instant = .now
    ) -> TuringSpokenPresentationContext {
        let route: TuringAudioRouteID
        switch interactionSurface {
        case .walkie:
            route = .storyWalkie
        case .dadFrame:
            route = .richHeadTracked
        case .crankRadio:
            route = .rollingBenchRadio
        case .hamReceiver:
            route = .hamReceiver
        }
        return TuringSpokenPresentationContext(
            run: run,
            playbackHandle: TuringAudioPlaybackHandle(
                id: id,
                requestID: id,
                runID: run.playbackRunID,
                route: route
            ),
            speakerCharacterID: speakerCharacterID,
            interactionSurface: interactionSurface,
            source: source,
            clockOrigin: clockOrigin,
            generatedSpeechFrameTrack: generatedSpeechFrameTrack
        )
    }
}

nonisolated enum TuringSpokenPresentationRevealOutcome: Sendable, Equatable {
    case revealed
    case alreadyVisible
    case audioOnly
}

nonisolated protocol MindEyeSpokenPresentationRevealStreaming: Sendable {
    func events() async -> AsyncStream<TuringSpokenPresentationRevealRequest>
}

nonisolated struct MindEyeGlobalSpokenPresentationRevealSource:
    MindEyeSpokenPresentationRevealStreaming,
    Sendable
{
    let hub: TuringSpokenPresentationRevealHub

    init(hub: TuringSpokenPresentationRevealHub = .shared) {
        self.hub = hub
    }

    func events() async -> AsyncStream<TuringSpokenPresentationRevealRequest> {
        await hub.events()
    }
}

actor TuringSpokenPresentationRevealHub {
    static let shared = TuringSpokenPresentationRevealHub()

    private var continuations: [
        UUID: AsyncStream<TuringSpokenPresentationRevealRequest>.Continuation
    ] = [:]
    private var activeRequestIDs = Set<UUID>()
    private var outcomes: [UUID: TuringSpokenPresentationRevealOutcome] = [:]

    func events() -> AsyncStream<TuringSpokenPresentationRevealRequest> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func requestReveal(
        _ request: TuringSpokenPresentationRevealRequest,
        timeout: Duration
    ) async -> TuringSpokenPresentationRevealOutcome? {
        guard continuations.isEmpty == false else { return .audioOnly }
        activeRequestIDs.insert(request.id)
        outcomes.removeValue(forKey: request.id)
        for continuation in continuations.values {
            continuation.yield(request)
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, Task.isCancelled == false {
            if let outcome = outcomes.removeValue(forKey: request.id) {
                activeRequestIDs.remove(request.id)
                return outcome
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        activeRequestIDs.remove(request.id)
        outcomes.removeValue(forKey: request.id)
        return nil
    }

    func resolve(
        requestID: UUID,
        outcome: TuringSpokenPresentationRevealOutcome
    ) {
        guard activeRequestIDs.contains(requestID) else { return }
        outcomes[requestID] = outcome
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
