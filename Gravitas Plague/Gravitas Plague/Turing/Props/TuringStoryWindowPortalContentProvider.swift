import Foundation
import RealityKit
import simd
import UIKit

struct TuringStoryWindowPortalContentProvider: PortalContentProvider {
    static let providerID = "turingStoryWindowDayNight"
    private static let groundDiscFloorOffsetMeters: Float = -2.5 * 0.3048

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
            opening: .window,
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
            context.floorY +
            Self.groundDiscFloorOffsetMeters
        let ground = try HordePortalGroundDiscFactory.makeGroundDisc(
            config: HordePortalGroundDiscFactory.Config(
                floorY: groundFloorY,
                centerZ: context.groundDiscCenterZ,
                radius: context.groundDiscRadius,
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
            opening: .window
        ).first {
            backdrop.orientation *= simd_quatf(
                angle: worldYawRadians,
                axis: SIMD3<Float>(0, 1, 0)
            )
        }

        print(
            """
            [TuringWindowPortal] portal world populated
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
