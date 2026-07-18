import Foundation
import RealityKit

@MainActor
final class TuringStoryDoorPortalResourceLoader {
    func populateFullExterior(
        portalWorld: Entity,
        atmosphere: PortalHDRIAtmosphere,
        placement: TuringStoryDoorBundlePlacement
    ) async throws {
        let provider = TuringStoryDoorPortalContentProvider(
            atmosphere: atmosphere,
            worldYawRadians: placement.worldYawRadians
        )
        try await provider.populatePortalWorld(
            portalWorld: portalWorld,
            context: .forDoor(
                width: placement.width,
                height: placement.height
            )
        )
    }

    func clearPreparedAndCachedExterior(
        portalWorld: Entity,
        reason: String
    ) {
        HDRIDomePortalContentProvider.releaseSharedResourceLease(
            portalWorld: portalWorld,
            reason: "doorExterior.\(reason)"
        )
    }
}
