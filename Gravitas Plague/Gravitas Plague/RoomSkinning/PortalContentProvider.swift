import Foundation
import RealityKit

protocol PortalContentProvider {
    var providerID: String { get }

    @MainActor
    func populatePortalWorld(
        portalWorld: Entity
    ) async throws
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
