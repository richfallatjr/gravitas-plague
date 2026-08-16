import Foundation

@MainActor
final class Chapter03Coordinator {
    private let progress: Chapter03ProgressStore
    private let definitionStore: Chapter03LightTunnelDefinitionStore
    private let lightTunnel: Chapter03LightTunnelCoordinator
    private let arbiter: StoryInteractionArbiter
    private let layoutFingerprintProvider:
        () throws -> TuringStoryEstablishedLayoutFingerprint
    private weak var blackout: ImmersiveBlackoutController?

    private(set) var state: Chapter03State = .idle
    private var chapterRunID: UUID?
    private var transitionLease: StoryInteractionLease?
    private var blackoutRequestID: UUID?

    var onEndCardRequested: ((
        StoryTitleCardTransitionRequest,
        StoryInteractionLease,
        UUID
    ) throws -> Void)?
    var onFailure: ((Error) -> Void)?

    init(
        lightTunnel: Chapter03LightTunnelCoordinator,
        layoutFingerprintProvider:
            @escaping () throws -> TuringStoryEstablishedLayoutFingerprint,
        progress: Chapter03ProgressStore = .shared,
        definitionStore: Chapter03LightTunnelDefinitionStore = .init(),
        arbiter: StoryInteractionArbiter = .shared
    ) {
        self.lightTunnel = lightTunnel
        self.layoutFingerprintProvider = layoutFingerprintProvider
        self.progress = progress
        self.definitionStore = definitionStore
        self.arbiter = arbiter

        lightTunnel.onCompleted = { [weak self] event in
            await self?.lightTunnelCompleted(event)
        }
        lightTunnel.onFailed = { [weak self] runID, error in
            await self?.lightTunnelFailed(runID: runID, error: error)
        }
    }

    func bind(blackout: ImmersiveBlackoutController) {
        self.blackout = blackout
        lightTunnel.bind(blackout: blackout)
    }

    func beginAtRoot(
        chapterRunID: UUID,
        transitionLease: StoryInteractionLease,
        blackoutRequestID: UUID,
        resetProgress: Bool
    ) async throws {
        guard Chapter03RootPlan.current == .lightTunnelTest else {
            throw Chapter03Error.authoredOpeningUnavailable
        }
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter03Error.storyStageNotEstablished
        }
        guard let blackout else {
            throw StoryTitleCardError.missingPresentationOwner
        }
        try await arbiter.requireCurrent(transitionLease)
        try blackout.requireFullBlackOwnership(requestID: blackoutRequestID)
        let before = try layoutFingerprintProvider()

        state = .acceptingRoot(chapterRunID)
        let resolved = try await definitionStore.loadProduction()
        if resetProgress {
            _ = try await progress.resetForReplay(sourceEventID: chapterRunID)
        }
        _ = try await progress.commit(
            .lightTunnelPending,
            sourceEventID: UUID()
        )

        self.chapterRunID = chapterRunID
        self.transitionLease = transitionLease
        self.blackoutRequestID = blackoutRequestID
        state = .preparingTunnel(chapterRunID)
        try await lightTunnel.start(
            Chapter03LightTunnelRequest(
                chapterRunID: chapterRunID,
                interactionLease: transitionLease,
                blackoutRequestID: blackoutRequestID,
                resolvedDefinition: resolved
            )
        )
        let after = try layoutFingerprintProvider()
        guard before == after else {
            throw Chapter03Error.layoutChangedDuringStart
        }
        state = .portalApproaching(chapterRunID)
        print(
            "[Chapter03] tunnel accepted under full black " +
                "runID=\(chapterRunID.uuidString) noRescan=true layoutPreserved=true"
        )
    }

    func resumeFromSavedCheckpoint(
        snapshot: Chapter03ProgressSnapshot,
        transitionLease: StoryInteractionLease,
        requestID: UUID
    ) async throws -> StoryTitleCardRouteLeaseDisposition {
        switch snapshot.checkpoint {
        case .root, .lightTunnelPending:
            try await beginAtRoot(
                chapterRunID: requestID,
                transitionLease: transitionLease,
                blackoutRequestID: requestID,
                resetProgress: false
            )
            return .destinationOwnsFullBlackAndLease
        case .endCardPending, .complete:
            try await arbiter.requireCurrent(transitionLease)
            self.chapterRunID = requestID
            self.transitionLease = transitionLease
            self.blackoutRequestID = requestID
            state = .ending(requestID)
            return .releaseAfterFade
        }
    }

    func markEndCardRouteCommitted(sourceEventID: UUID) async throws {
        _ = try await progress.commit(.complete, sourceEventID: sourceEventID)
        state = .complete
        chapterRunID = nil
        transitionLease = nil
        blackoutRequestID = nil
        print("[Chapter03] complete end-card route committed")
    }

    func cancel(reason: String) async {
        let runID = chapterRunID
        await lightTunnel.cancel(reason: reason)
        if let blackoutRequestID {
            blackout?.cancelTitleTransition(
                requestID: blackoutRequestID,
                restoreImmediately: true
            )
        }
        if let transitionLease {
            let snapshot = await arbiter.currentSnapshot()
            if snapshot.exclusiveOwner == transitionLease.owner {
                await arbiter.release(transitionLease, reason: reason)
            }
        }
        chapterRunID = nil
        transitionLease = nil
        blackoutRequestID = nil
        state = .cancelled
        if let runID {
            print("[Chapter03] cancelled runID=\(runID.uuidString) reason=\(reason)")
        }
    }

    private func lightTunnelCompleted(
        _ event: Chapter03LightTunnelCompletedEvent
    ) async {
        guard chapterRunID == event.chapterRunID,
              event.musicActuallyCompleted,
              transitionLease == event.interactionLease,
              blackoutRequestID == event.blackoutRequestID else {
            return
        }
        do {
            try await arbiter.requireCurrent(event.interactionLease)
            _ = try await progress.commit(
                .endCardPending,
                sourceEventID: event.completionEventID
            )
            state = .ending(event.chapterRunID)
            let request = StoryTitleCardTransitionRequest(
                requestID: event.chapterRunID,
                source: .naturalEpisodeBoundary,
                descriptor: StoryTitleCardCatalog.endOfAvailableContent,
                destination: .endOfAvailableContent(
                    completedEpisode: .chapter03
                ),
                menuMusicPolicy: .unchanged
            )
            guard let onEndCardRequested else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try onEndCardRequested(
                request,
                event.interactionLease,
                event.blackoutRequestID
            )
        } catch {
            await lightTunnelFailed(runID: event.chapterRunID, error: error)
        }
    }

    private func lightTunnelFailed(runID: UUID, error: Error) async {
        guard chapterRunID == runID else { return }
        if let blackoutRequestID, let blackout {
            do {
                try await blackout.fadeBackUp(
                    duration: .milliseconds(300),
                    requestID: blackoutRequestID
                )
            } catch {
                blackout.cancelTitleTransition(
                    requestID: blackoutRequestID,
                    restoreImmediately: true
                )
            }
        }
        if let transitionLease {
            await arbiter.release(
                transitionLease,
                reason: "chapter03.lightTunnelFailed"
            )
        }
        state = .failed(runID, error.localizedDescription)
        chapterRunID = nil
        transitionLease = nil
        blackoutRequestID = nil
        onFailure?(error)
    }
}
