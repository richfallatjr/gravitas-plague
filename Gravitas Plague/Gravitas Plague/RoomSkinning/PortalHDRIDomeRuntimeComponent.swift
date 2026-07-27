import Foundation
import RealityKit

enum StoryPortalOpening:
    String,
    Sendable,
    Equatable,
    Hashable,
    Codable
{
    case door
    case window
}

struct PortalHDRIDomeRuntimeComponent:
    Component,
    Codable
{
    let opening: StoryPortalOpening?
    let providerType: String
    let atmosphereID: String
    let radiusMeters: Float
    let centerOffsetZ: Float
    let nearestShellDistanceMeters: Float
    let meshWinding: PortalHDRIDomeMeshWinding
    let surfaceContract: PortalHDRIDomeSurfaceContract
    let ownerID: UUID
}

enum PortalHDRIDomeComponents {
    private static var registered = false

    @MainActor
    static func registerIfNeeded() {
        guard registered == false else {
            return
        }

        PortalHDRIDomeRuntimeComponent.registerComponent()
        registered = true
    }
}
