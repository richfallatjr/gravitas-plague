import Combine
import Foundation

enum TuringStoryDoorPortalOwner: Hashable, Sendable {
    case player
    case battle(UUID)
}

struct TuringStoryDoorPortalLease: Hashable, Sendable {
    let id: UUID
    let owner: TuringStoryDoorPortalOwner
}

enum TuringStoryDoorPortalState: Equatable, Sendable {
    case closedUnloaded
    case loading(requestID: UUID, owner: TuringStoryDoorPortalOwner)
    case closedReady(leaseID: UUID, owner: TuringStoryDoorPortalOwner)
    case opening(leaseID: UUID, owner: TuringStoryDoorPortalOwner)
    case open(leaseID: UUID, owner: TuringStoryDoorPortalOwner)
    case closing(leaseID: UUID, owner: TuringStoryDoorPortalOwner)
    case unloading(requestID: UUID)
    case failed(message: String)
}

enum TuringStoryDoorInteractionPresentation: Equatable, Sendable {
    case hidden
    case open
    case close
}

@MainActor
final class TuringStoryDoorPortalLifecycleController: ObservableObject {
    @Published private(set) var state: TuringStoryDoorPortalState =
        .closedUnloaded

    private(set) var activeLease: TuringStoryDoorPortalLease?
    private(set) var battleInteractionLocked = false
    private(set) var turingPreflightActive = false

    var presentation: TuringStoryDoorInteractionPresentation {
        guard battleInteractionLocked == false,
              turingPreflightActive == false else {
            return .hidden
        }

        switch state {
        case .closedUnloaded:
            return .open
        case .loading(_, .battle), .closedReady(_, .battle):
            return .open
        case .open(_, .player):
            return .close
        case .loading, .closedReady, .opening, .closing, .unloading,
             .failed, .open:
            return .hidden
        }
    }

    var isBattleOwned: Bool {
        guard case .battle = activeLease?.owner else { return false }
        return true
    }

    func beginPlayerOpen() -> (
        lease: TuringStoryDoorPortalLease,
        requestID: UUID
    )? {
        guard state == .closedUnloaded,
              activeLease == nil,
              battleInteractionLocked == false,
              turingPreflightActive == false else {
            return nil
        }

        let lease = TuringStoryDoorPortalLease(
            id: UUID(),
            owner: .player
        )
        let requestID = UUID()
        activeLease = lease
        state = .loading(requestID: requestID, owner: lease.owner)
        return (lease, requestID)
    }

    func acquireForBattle(
        battleInstanceID: UUID,
        fullExteriorLoaded: Bool,
        doorState: TuringStoryDoorBattleState
    ) -> TuringStoryDoorPortalLease {
        if let activeLease,
           activeLease.owner == .battle(battleInstanceID) {
            return activeLease
        }

        let lease = TuringStoryDoorPortalLease(
            id: UUID(),
            owner: .battle(battleInstanceID)
        )
        activeLease = lease
        if fullExteriorLoaded {
            switch doorState {
            case .closed:
                state = .closedReady(leaseID: lease.id, owner: lease.owner)
            case .opening:
                state = .opening(leaseID: lease.id, owner: lease.owner)
            case .open:
                state = .open(leaseID: lease.id, owner: lease.owner)
            case .closing:
                state = .closing(leaseID: lease.id, owner: lease.owner)
            }
        } else {
            state = .loading(requestID: UUID(), owner: lease.owner)
        }
        return lease
    }

    func markLoading(requestID: UUID, lease: TuringStoryDoorPortalLease) {
        guard activeLease == lease else { return }
        state = .loading(requestID: requestID, owner: lease.owner)
    }

    func markClosedReady(lease: TuringStoryDoorPortalLease) {
        guard activeLease == lease else { return }
        state = .closedReady(leaseID: lease.id, owner: lease.owner)
    }

    func markOpening(lease: TuringStoryDoorPortalLease) {
        guard activeLease == lease else { return }
        state = .opening(leaseID: lease.id, owner: lease.owner)
    }

    func markOpen(lease: TuringStoryDoorPortalLease) {
        guard activeLease == lease else { return }
        state = .open(leaseID: lease.id, owner: lease.owner)
    }

    func markClosing(lease: TuringStoryDoorPortalLease) {
        guard activeLease == lease else { return }
        state = .closing(leaseID: lease.id, owner: lease.owner)
    }

    func markUnloading(requestID: UUID, lease: TuringStoryDoorPortalLease) {
        guard activeLease == lease else { return }
        state = .unloading(requestID: requestID)
    }

    func finishUnloaded(lease: TuringStoryDoorPortalLease?) {
        if let lease,
           activeLease != lease {
            return
        }
        activeLease = nil
        state = .closedUnloaded
    }

    func fail(_ error: Error, lease: TuringStoryDoorPortalLease?) {
        if let lease,
           activeLease != lease {
            return
        }
        activeLease = nil
        state = .failed(message: error.localizedDescription)
    }

    func recoverClosedUnloaded() {
        activeLease = nil
        state = .closedUnloaded
    }

    func setBattleInteractionLocked(_ locked: Bool) {
        battleInteractionLocked = locked
    }

    func setTuringPreflightActive(_ active: Bool) {
        turingPreflightActive = active
    }

    func reset() {
        activeLease = nil
        battleInteractionLocked = false
        turingPreflightActive = false
        state = .closedUnloaded
    }
}
