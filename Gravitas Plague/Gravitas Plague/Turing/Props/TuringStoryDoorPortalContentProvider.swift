import Foundation
import RealityKit
import simd

struct TuringStoryDoorPortalContentProvider: PortalContentProvider {
    static let providerID = "turingStoryDoorDayNightHellscapePlaceholder"

    var providerID: String { Self.providerID }

    let atmosphere: PortalHDRIAtmosphere
    let worldYawRadians: Float

    @MainActor
    func populatePortalWorld(
        portalWorld: Entity,
        context: PortalContentContext
    ) async throws {
        portalWorld.children.removeAll()
        portalWorld.components.set(WorldComponent())
        PlagueNativeBloomInstaller.installStrictBloom(
            on: portalWorld
        )

        let hdriProvider = HDRIDomePortalContentProvider(
            atmosphere: atmosphere
        )
        try await hdriProvider.populatePortalWorld(
            portalWorld: portalWorld,
            context: PortalContentContext(
                doorWidth: context.doorWidth,
                doorHeight: context.doorHeight,
                floorY: context.floorY,
                groundDiscEnabled: false,
                groundDiscRadius: context.groundDiscRadius,
                groundDiscCenterZ: context.groundDiscCenterZ
            )
        )

        let groundFloorY = context.floorY + 0.004
        let ground = try HordePortalGroundDiscFactory.makeGroundDisc(
            config: HordePortalGroundDiscFactory.Config(
                floorY: groundFloorY,
                centerZ: context.groundDiscCenterZ,
                radius: context.groundDiscRadius,
                segments: 96,
                featherRingCount: 8,
                featherStartFraction: 0.72,
                textureName: "hellscape_groundplane",
                exposure: 1.0
            )
        )
        portalWorld.addChild(ground)

        if let backdrop = portalWorld.findEntity(
            named: "PortalHDRIDome_\(atmosphere.exrResourceName)"
        ) {
            backdrop.orientation *= simd_quatf(
                angle: worldYawRadians,
                axis: SIMD3<Float>(0, 1, 0)
            )
        }

        print(
            """
            [TuringDoorPortal] portal world populated
              atmosphere: \(atmosphere.rawValue)
              domeEXR: \(atmosphere.exrResourceName).exr
              ground: hellscape_groundplane.png
              groundMode: horde_faded_disc
              featherRingCount: 8
              featherStartFraction: 0.72
              groundFloorY: \(groundFloorY)
              worldYawRadians: \(worldYawRadians)
            """
        )
    }
}
