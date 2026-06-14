import RealityKit
import simd
import UIKit

@MainActor
enum PortalGlyphDecalFactory {
    static func makeWallGlyph(
        placement: PortalGlyphPlacement
    ) -> ModelEntity {
        let entity = ModelEntity(
            mesh: .generatePlane(
                width: placement.size.x,
                height: placement.size.y
            ),
            materials: [
                material(
                    for: placement.asset
                )
            ]
        )

        entity.name = "PortalWallGlyph_\(placement.asset.fileName)"
        entity.position = SIMD3<Float>(
            placement.center2D.x,
            placement.center2D.y,
            PortalGlyphFXSettings.wallDepthOffset
        )
        entity.orientation = simd_quatf(
            angle: placement.rotationRadians,
            axis: SIMD3<Float>(0, 0, 1)
        )

        stripInput(entity)

        return entity
    }

    static func makeFloorGlyph(
        placement: PortalGlyphPlacement,
        floorY: Float,
        portalWorldFromLocal: simd_float4x4
    ) -> ModelEntity {
        let entity = ModelEntity(
            mesh: makeFloorPlaneMesh(
                width: placement.size.x,
                height: placement.size.y
            ),
            materials: [
                material(
                    for: placement.asset
                )
            ]
        )

        entity.name = "PortalFloorGlyph_\(placement.asset.fileName)"

        let local = SIMD3<Float>(
            placement.center2D.x,
            0,
            placement.center2D.y
        )

        let world = transformPoint(
            portalWorldFromLocal,
            local
        )

        entity.setPosition(
            SIMD3<Float>(
                world.x,
                floorY + PortalGlyphFXSettings.floorLift,
                world.z
            ),
            relativeTo: nil
        )

        let portalRight = normalizeSafe3(
            SIMD3<Float>(
                portalWorldFromLocal.columns.0.x,
                0,
                portalWorldFromLocal.columns.0.z
            ),
            fallback: SIMD3<Float>(1, 0, 0)
        )

        let basisYaw = atan2(
            portalRight.z,
            portalRight.x
        )

        entity.orientation = simd_quatf(
            angle: basisYaw + placement.rotationRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )

        stripInput(entity)

        return entity
    }

    private static func material(
        for asset: PortalGlyphAsset
    ) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(
            tint: PortalGlyphFXSettings.baseTint,
            texture: .init(asset.texture)
        )
        material.roughness = .init(floatLiteral: 0.86)
        material.metallic = .init(floatLiteral: 0.0)
        material.emissiveColor = .init(
            color: PortalGlyphFXSettings.emissiveTint
        )
        material.emissiveIntensity = .init(
            floatLiteral: PortalGlyphFXSettings.emissiveIntensity
        )
        material.blending = .transparent(
            opacity: .init(floatLiteral: 1.0)
        )
        material.faceCulling = .none

        return material
    }

    private static func makeFloorPlaneMesh(
        width: Float,
        height: Float
    ) -> MeshResource {
        let halfWidth = width * 0.5
        let halfHeight = height * 0.5

        var descriptor = MeshDescriptor(
            name: "PortalFloorGlyphPlane"
        )
        descriptor.positions = MeshBuffers.Positions([
            SIMD3<Float>(-halfWidth, 0, -halfHeight),
            SIMD3<Float>( halfWidth, 0, -halfHeight),
            SIMD3<Float>(-halfWidth, 0,  halfHeight),
            SIMD3<Float>( halfWidth, 0,  halfHeight)
        ])
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 1),
            SIMD2<Float>(1, 1)
        ])
        descriptor.primitives = .triangles([
            0, 1, 2,
            2, 1, 3,
            2, 1, 0,
            3, 1, 2
        ])

        do {
            return try MeshResource.generate(
                from: [descriptor]
            )
        } catch {
            assertionFailure("Portal floor glyph plane mesh failed: \(error.localizedDescription)")
            return .generatePlane(
                width: width,
                height: height
            )
        }
    }

    private static func stripInput(
        _ entity: Entity
    ) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)
    }
}

private func transformPoint(
    _ matrix: simd_float4x4,
    _ point: SIMD3<Float>
) -> SIMD3<Float> {
    let p = matrix * SIMD4<Float>(
        point.x,
        point.y,
        point.z,
        1
    )

    return SIMD3<Float>(
        p.x,
        p.y,
        p.z
    )
}

private func normalizeSafe3(
    _ vector: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(vector)

    guard length > 0.00001 else {
        return fallback
    }

    return vector / length
}
