import Foundation
import RealityKit

protocol PortalContentProvider {
    var providerID: String { get }

    @MainActor
    func populatePortalWorld(
        portalWorld: Entity,
        context: PortalContentContext
    ) async throws
}

extension PortalContentProvider {
    @MainActor
    func populatePortalWorld(
        portalWorld: Entity
    ) async throws {
        try await populatePortalWorld(
            portalWorld: portalWorld,
            context: .forDoor(
                width: 0.92,
                height: 2.0
            )
        )
    }
}

enum PortalContentProviderRegistry {
    static func requireProvider(
        id: String,
        atmosphere: PortalHDRIAtmosphere,
        ownerID: UUID
    ) throws -> PortalContentProvider {
        switch id {
        case HDRIDomePortalContentProvider.providerID,
             "environmentSphere":
            return HDRIDomePortalContentProvider(
                atmosphere: atmosphere,
                placement: .centeredLegacy,
                surfaceContract: .legacyPreserveCurrentBehavior,
                opening: nil,
                providerType: "LegacyPortalContentProviderRegistry",
                ownerID: ownerID
            )

        default:
#if DEBUG
            assertionFailure("Unknown portal provider: \(id)")
#endif
            throw PortalHDRIDomeError.unknownProvider(id)
        }
    }
}
