import Foundation
import RealityKit
import simd
import UIKit

struct TuringStoryWindowPortalContentProvider: PortalContentProvider {
    static let providerID = "turingStoryWindowDayNight"

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

        let ground = try makeHellscapePlaceholderGround(
            context: context
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
            [TuringWindowPortal] portal world populated
              atmosphere: \(atmosphere.rawValue)
              domeEXR: \(atmosphere.exrResourceName).exr
              ground: hellscape_groundplane.png
              groundPlaceholder: true
              worldYawRadians: \(worldYawRadians)
            """
        )
    }

    @MainActor
    private func makeHellscapePlaceholderGround(
        context: PortalContentContext
    ) throws -> ModelEntity {
        guard let texture = try? TextureResource.load(
            named: "hellscape_groundplane"
        ) else {
            throw NSError(
                domain: "TuringWindowPortal",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey: "Missing hellscape_groundplane.png"
                ]
            )
        }

        var material = UnlitMaterial()
        material.color = .init(
            tint: .white,
            texture: .init(texture)
        )
        material.faceCulling = .none

        let ground = ModelEntity(
            mesh: .generatePlane(
                width: context.groundDiscRadius * 2.0,
                depth: context.groundDiscRadius * 2.0
            ),
            materials: [material]
        )
        ground.name = "TuringStoryWindow_HellscapeGroundPlaceholder"
        ground.position = SIMD3<Float>(
            0,
            context.floorY + 0.004,
            context.groundDiscCenterZ
        )
        ground.orientation = simd_quatf(
            angle: -.pi / 2,
            axis: SIMD3<Float>(1, 0, 0)
        )

        return ground
    }
}
