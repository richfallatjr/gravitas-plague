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
    static func provider(
        id: String,
        atmosphere: PortalHDRIAtmosphere = .night
    ) -> PortalContentProvider {
        switch id {
        case HDRIDomePortalContentProvider.providerID,
             "environmentSphere":
            return HDRIDomePortalContentProvider(
                atmosphere: atmosphere
            )

        default:
            print(
                """
                [PortalContentProviderRegistry] unknown provider \(id), using HDRI dome provider
                """
            )
            return HDRIDomePortalContentProvider(
                atmosphere: atmosphere
            )
        }
    }
}
