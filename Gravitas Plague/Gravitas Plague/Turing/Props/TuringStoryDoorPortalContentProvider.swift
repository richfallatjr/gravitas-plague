import Foundation
import RealityKit
import simd

struct TuringStoryDoorPortalContentProvider: PortalContentProvider {
    static let providerID = "turingStoryDoorDayNight"
    private static let portalLocalGroundY: Float = 0.0
    private static let groundDiscFloorOffsetMeters: Float = -6.0 * 0.0254

    var providerID: String { Self.providerID }

    let atmosphere: PortalHDRIAtmosphere
    let worldYawRadians: Float
    let ownerID: UUID

    @MainActor
    func populatePortalWorld(
        portalWorld: Entity,
        context: PortalContentContext
    ) async throws {
        let hdriProvider = HDRIDomePortalContentProvider(
            atmosphere: atmosphere,
            placement: .storyOpening,
            surfaceContract: .storyInteriorOnly,
            opening: .door,
            providerType: String(describing: Self.self),
            ownerID: ownerID
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

        let groundTextureName = groundTextureName(
            for: atmosphere
        )
        let groundFloorY =
            Self.portalLocalGroundY +
            Self.groundDiscFloorOffsetMeters
        let ground = try HordePortalGroundDiscFactory.makeGroundDisc(
            config: HordePortalGroundDiscFactory.Config(
                floorY: groundFloorY,
                centerZ: context.groundDiscCenterZ,
                radius: context.groundDiscRadius,
                segments: 96,
                featherRingCount: 8,
                featherStartFraction: 0.72,
                textureName: groundTextureName,
                exposure: atmosphere.visibleExposure,
                yawOffsetRadians: worldYawRadians
            )
        )
        portalWorld.addChild(ground)

        if let backdrop = PortalHDRIDomeRuntimeDiagnostics.storyDomes(
            in: portalWorld,
            opening: .door
        ).first {
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
              domeRadius: \(PortalHDRIDomePlacementTuning.storyOpeningRadiusMeters)
              domeCenterOffsetZ: \(PortalHDRIDomePlacementTuning.storyOpeningCenterOffsetZ)
              nearestDomeShellDistance: \(PortalHDRIDomePlacementTuning.storyOpeningCameraClearanceMeters)
              surfaceContract: \(PortalHDRIDomeSurfaceContract.storyInteriorOnly.rawValue)
              ownerID: \(ownerID.uuidString)
              ground: \(groundTextureName).png
              groundMode: horde_faded_disc
              featherRingCount: 8
              featherStartFraction: 0.72
              inputContextFloorY: \(context.floorY)
              portalLocalGroundY: \(Self.portalLocalGroundY)
              groundFloorOffsetMeters: \(Self.groundDiscFloorOffsetMeters)
              groundFloorY: \(groundFloorY)
              groundYawOffsetRadians: \(worldYawRadians)
              worldYawRadians: \(worldYawRadians)
            """
        )
    }

    private func groundTextureName(
        for atmosphere: PortalHDRIAtmosphere
    ) -> String {
        switch atmosphere {
        case .overcast:
            return "day-groundplane-tile"

        case .night:
            return "night-groundplane-tile"
        }
    }
}
