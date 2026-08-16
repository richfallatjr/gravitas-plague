import Foundation
import RealityKit

@MainActor
final class CinematicWorldPresentationCoordinator {
    enum Owner: Equatable {
        case titleCard(UUID)
        case death(UUID)
        case chapter03LightTunnel(UUID)
    }

    private weak var worldAnchor: AnchorEntity?
    private(set) var owner: Owner?

    func bind(worldAnchor: AnchorEntity) {
        self.worldAnchor = worldAnchor
    }

    func claimChapter03LightTunnel(runID: UUID) throws -> AnchorEntity {
        guard let worldAnchor else {
            throw Chapter03Error.cinematicAnchorUnavailable
        }
        guard owner == nil || owner == .chapter03LightTunnel(runID) else {
            throw Chapter03Error.cinematicAnchorOwned
        }
        owner = .chapter03LightTunnel(runID)
        print("[CinematicWorld] claimed owner=chapter03LightTunnel runID=\(runID.uuidString)")
        return worldAnchor
    }

    func releaseChapter03LightTunnel(runID: UUID) {
        guard owner == .chapter03LightTunnel(runID) else { return }
        owner = nil
        print("[CinematicWorld] released owner=chapter03LightTunnel runID=\(runID.uuidString)")
    }

    @discardableResult
    func claimDeath(runID: UUID) -> Bool {
        let preemptedTunnel: Bool
        if case .chapter03LightTunnel = owner {
            preemptedTunnel = true
        } else {
            preemptedTunnel = false
        }
        owner = .death(runID)
        return preemptedTunnel
    }

    func releaseDeath(runID: UUID) {
        guard owner == .death(runID) else { return }
        owner = nil
    }
}
