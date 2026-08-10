import Combine
import Foundation
import simd

@MainActor
protocol StoryTitleCardTransitionWorld: AnyObject {
    func currentTitleCardDeviceTransform() -> simd_float4x4?

    func acquireTitleCardTransitionLease(
        transitionID: UUID,
        source: String
    ) async throws -> StoryInteractionLease

    func commitTitleCardDestination(
        _ destination: StoryTitleCardDestination,
        transitionLease: StoryInteractionLease,
        requestID: UUID
    ) async throws -> StoryTitleCardRouteLeaseDisposition

    func titleCardTransitionDidFullyFade(
        _ destination: StoryTitleCardDestination,
        requestID: UUID
    ) async throws

    func titleCardTransitionCompleted(
        _ destination: StoryTitleCardDestination,
        requestID: UUID
    ) async

    func titleCardTransitionFailed(
        _ error: Error,
        request: StoryTitleCardTransitionRequest
    )
}

enum StoryTitleCardTransitionState: Sendable, Equatable {
    case idle
    case fadingToBlack(UUID)
    case presenting(UUID, StoryTitleCardDescriptor.CardID)
    case committingRoute(UUID)
    case fadingFromBlack(UUID)
}

@MainActor
final class StoryTitleCardTransitionCoordinator: ObservableObject {
    @Published private(set) var state: StoryTitleCardTransitionState = .idle
    @Published private(set) var lastError: String?

    private weak var world: (any StoryTitleCardTransitionWorld)?
    private weak var presenter: StoryTitleCardWorldPresenter?
    private weak var blackout: ImmersiveBlackoutController?
    private var activeTask: Task<Void, Never>?
    private var activeRequestID: UUID?

    func bind(
        world: any StoryTitleCardTransitionWorld,
        presenter: StoryTitleCardWorldPresenter,
        blackout: ImmersiveBlackoutController
    ) {
        self.world = world
        self.presenter = presenter
        self.blackout = blackout
    }

    func accept(
        _ request: StoryTitleCardTransitionRequest,
        ownership: StoryTitleCardLeaseOrigin = .acquireFromStableState
    ) throws {
        guard activeTask == nil,
              activeRequestID == nil,
              state == .idle else {
            throw StoryTitleCardError.transitionAlreadyActive
        }

        activeRequestID = request.requestID
        lastError = nil
        print(
            """
            [StoryTitleCard] request accepted
              requestID: \(request.requestID.uuidString)
              source: \(request.source.rawValue)
              cardID: \(request.descriptor.id.rawValue)
              destination: \(request.destination)
              menuMusicPolicy: \(request.menuMusicPolicy.rawValue)
            """
        )

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performAccepted(
                    request,
                    ownership: ownership
                )
            } catch is CancellationError {
                await self.finishCancelled(request: request)
            } catch {
                await self.finishFailed(error, request: request)
            }
        }
    }

    func cancelForDeath() {
        guard let requestID = activeRequestID else { return }
        activeTask?.cancel()
        presenter?.remove(requestID: requestID)
        blackout?.cancelTitleTransition(
            requestID: requestID,
            restoreImmediately: false
        )
        activeTask = nil
        activeRequestID = nil
        state = .idle
        print("[StoryTitleCard] cancelled reason=playerDeath")
    }

    func reset(reason: String) {
        let requestID = activeRequestID
        activeTask?.cancel()
        activeTask = nil
        if let requestID {
            presenter?.remove(requestID: requestID)
            blackout?.cancelTitleTransition(
                requestID: requestID,
                restoreImmediately: true
            )
        }
        presenter?.removeAll(reason: reason)
        activeRequestID = nil
        state = .idle
        lastError = nil
        print("[StoryTitleCard] reset reason=\(reason)")
    }

    private func performAccepted(
        _ request: StoryTitleCardTransitionRequest,
        ownership: StoryTitleCardLeaseOrigin
    ) async throws {
        guard let world,
              let presenter,
              let blackout else {
            throw StoryTitleCardError.missingPresentationOwner
        }

        let lease: StoryInteractionLease
        switch ownership {
        case .acquireFromStableState:
            lease = try await world.acquireTitleCardTransitionLease(
                transitionID: request.requestID,
                source: request.source.rawValue
            )
        case .transferred(let transferred):
            try await StoryInteractionArbiter.shared.requireCurrent(transferred)
            guard case .storyTransition(let transitionID) = transferred.owner,
                  transitionID == request.requestID else {
                throw StoryInteractionClaimError.invalidTransfer
            }
            lease = transferred
        }

        if request.menuMusicPolicy == .stopOnAcceptance {
            await PlagueMainMenuMusicActor.shared.stop(
                reason: "titleCardAccepted.\(request.source.rawValue)"
            )
        }

        try requireCurrent(request.requestID)
        guard let originFromDevice = world.currentTitleCardDeviceTransform() else {
            throw StoryTitleCardError.missingTrackedDevicePose
        }
        print(
            "[StoryTitleCard] device pose captured requestID=" +
                request.requestID.uuidString +
                " originFromDeviceColumnW=\(originFromDevice.columns.3)"
        )

        state = .fadingToBlack(request.requestID)
        try await blackout.fadeToFullBlack(
            duration: request.descriptor.fadeToBlackSeconds,
            requestID: request.requestID
        )
        try requireCurrent(request.requestID)
        try await StoryInteractionArbiter.shared.requireCurrent(lease)
        print(
            "[StoryTitleCard] full black reached requestID=" +
                request.requestID.uuidString + " opacity=1.0"
        )

        try presenter.show(
            requestID: request.requestID,
            descriptor: request.descriptor,
            originFromDevice: originFromDevice
        )
        state = .presenting(request.requestID, request.descriptor.id)
        try await ContinuousClock().sleep(for: request.descriptor.holdSeconds)
        try requireCurrent(request.requestID)

        presenter.remove(requestID: request.requestID)

        state = .committingRoute(request.requestID)
        let disposition = try await world.commitTitleCardDestination(
            request.destination,
            transitionLease: lease,
            requestID: request.requestID
        )
        try requireCurrent(request.requestID)

        state = .fadingFromBlack(request.requestID)
        try await blackout.fadeBackUp(
            duration: request.descriptor.fadeFromBlackSeconds,
            requestID: request.requestID
        )
        try requireCurrent(request.requestID)
        try await world.titleCardTransitionDidFullyFade(
            request.destination,
            requestID: request.requestID
        )

        if request.menuMusicPolicy == .playThroughCard {
            await PlagueMainMenuMusicActor.shared.stop(
                reason: "titleCardBlackoutFullyFaded.\(request.source.rawValue)"
            )
            print(
                "[StoryTitleCard] Continue menu music stopped after blackout fully faded " +
                "requestID=\(request.requestID.uuidString) opacity=0.0"
            )
        }

        if request.destination.stopsPrologueAftermathAfterFade {
            await StoryAftermathMusicActor.shared.stop(
                reason:
                    "chapter01TitleCardBlackoutFullyFaded.\(request.source.rawValue)"
            )
            print(
                "[StoryTitleCard] Battle01 aftermath music stopped after " +
                    "Chapter 1 blackout fully faded requestID=" +
                    request.requestID.uuidString + " opacity=0.0"
            )
        }

        if request.destination.stopsChapter02BattleMusicAfterFade {
            await Chapter02BattleMusicActor.shared.stop(
                reason:
                    "chapter02TitleCardBlackoutFullyFaded.\(request.source.rawValue)"
            )
            print(
                "[StoryTitleCard] Chapter 2 battle music stopped after " +
                    "the next title card fully faded requestID=" +
                    request.requestID.uuidString + " opacity=0.0"
            )
        }

        if disposition == .releaseAfterFade {
            await StoryInteractionArbiter.shared.release(
                lease,
                reason: "titleCardCompleted.\(request.descriptor.id.rawValue)"
            )
        }

        let interaction = await StoryInteractionArbiter.shared.currentSnapshot()

        activeTask = nil
        activeRequestID = nil
        state = .idle
        await world.titleCardTransitionCompleted(
            request.destination,
            requestID: request.requestID
        )
        print(
            "[StoryTitleCard] completed requestID=" +
                request.requestID.uuidString +
                " routeLeaseDisposition=\(disposition)" +
                " interactionOwner=\(interaction.exclusiveOwner?.logValue ?? "none")" +
                " stableCapabilities=\(interaction.capabilities.map(\.rawValue).sorted())"
        )
    }

    private func finishCancelled(
        request: StoryTitleCardTransitionRequest
    ) async {
        presenter?.remove(requestID: request.requestID)
        blackout?.cancelTitleTransition(
            requestID: request.requestID,
            restoreImmediately: true
        )
        await StoryInteractionArbiter.shared.releaseCurrentStoryTransition(
            transitionID: request.requestID,
            reason: "titleCardCancelled"
        )
        activeTask = nil
        activeRequestID = nil
        state = .idle
    }

    private func finishFailed(
        _ error: Error,
        request: StoryTitleCardTransitionRequest
    ) async {
        presenter?.remove(requestID: request.requestID)
        if let blackout {
            do {
                try await blackout.fadeBackUp(
                    duration: .milliseconds(300),
                    requestID: request.requestID
                )
            } catch {
                blackout.cancelTitleTransition(
                    requestID: request.requestID,
                    restoreImmediately: true
                )
            }
        }
        let snapshot = await StoryInteractionArbiter.shared.currentSnapshot()
        if case .storyTransition(let transitionID) = snapshot.exclusiveOwner,
           transitionID == request.requestID {
            await StoryInteractionArbiter.shared.releaseCurrentStoryTransition(
                transitionID: transitionID,
                reason: "titleCardFailed"
            )
        }
        try? await PlagueMainMenuMusicActor.shared.startIfNeeded(
            reason: "titleCardFailed.\(request.source.rawValue)"
        )
        world?.titleCardTransitionFailed(error, request: request)
        lastError = error.localizedDescription
        activeTask = nil
        activeRequestID = nil
        state = .idle
        print(
            "[StoryTitleCard] ERROR requestID=\(request.requestID.uuidString) " +
                "error=\(error.localizedDescription)"
        )
    }

    private func requireCurrent(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard activeRequestID == requestID else {
            throw StoryTitleCardError.staleRequest
        }
    }
}
