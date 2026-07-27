import Foundation
import RealityKit

@MainActor
final class TuringStoryDoorPortalResourceLoader {
    private let storyDomeOwnerID = UUID()

    func populateFullExterior(
        portalWorld: Entity,
        atmosphere: PortalHDRIAtmosphere,
        placement: TuringStoryDoorBundlePlacement
    ) async throws {
        let provider = TuringStoryDoorPortalContentProvider(
            atmosphere: atmosphere,
            worldYawRadians: placement.worldYawRadians,
            ownerID: storyDomeOwnerID
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
