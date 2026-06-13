import CoreGraphics
import RealityKit
import simd
import UIKit

enum PortalProjectedGroundDiscFactory {
    struct Config {
        var floorY: Float
        var centerZ: Float
        var radius: Float

        var segments: Int = 96
        var featherRingCount: Int = 8
        var featherStartFraction: Float = 0.70
        var projectionOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
        var yawOffsetRadians: Float = 0
        var exposure: Float = 1.0
    }

    @MainActor
    static func makeGroundDisc(
        texture: TextureResource,
        config: Config
    ) throws -> Entity {
        let root = Entity()
        root.name = "PortalProjectedGroundDiscRoot"

        let innerRadius = config.radius * config.featherStartFraction

        let core = try makeDiscMeshEntity(
            texture: texture,
            innerRadius: 0,
            outerRadius: innerRadius,
            alpha: 1.0,
            config: config,
            name: "PortalProjectedGroundDisc_Core"
        )

        root.addChild(core)

        for ring in 0..<config.featherRingCount {
            let t0 = Float(ring) / Float(config.featherRingCount)
            let t1 = Float(ring + 1) / Float(config.featherRingCount)
            let radius0 = innerRadius + (config.radius - innerRadius) * t0
            let radius1 = innerRadius + (config.radius - innerRadius) * t1
            let alpha = pow(1.0 - t0, 1.7) * 0.82

            let entity = try makeDiscMeshEntity(
                texture: texture,
                innerRadius: radius0,
                outerRadius: radius1,
                alpha: alpha,
                config: config,
                name: "PortalProjectedGroundDisc_Feather_\(ring)"
            )

            root.addChild(entity)
        }

        print(
            """
            [PortalGroundDisc] projected EXR ground disc created
              floorY: \(config.floorY)
              centerZ: \(config.centerZ)
              radius: \(config.radius)
              featherRings: \(config.featherRingCount)
              projection: equirectangular_downward
            """
        )

        return root
    }
}

private extension PortalProjectedGroundDiscFactory {
    static func makeDiscMeshEntity(
        texture: TextureResource,
        innerRadius: Float,
        outerRadius: Float,
        alpha: Float,
        config: Config,
        name: String
    ) throws -> ModelEntity {
        let mesh = try makeAnnulusMesh(
            innerRadius: innerRadius,
            outerRadius: outerRadius,
            config: config
        )

        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor(
                red: CGFloat(config.exposure),
                green: CGFloat(config.exposure),
                blue: CGFloat(config.exposure),
                alpha: CGFloat(alpha)
            ),
            texture: .init(texture)
        )
        material.blending = .transparent(
            opacity: .init(floatLiteral: max(0.001, alpha))
        )
        material.faceCulling = .none

        let entity = ModelEntity(
            mesh: mesh,
            materials: [material]
        )

        entity.name = name
        return entity
    }

    static func makeAnnulusMesh(
        innerRadius: Float,
        outerRadius: Float,
        config: Config
    ) throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var textureCoordinates: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        let segments = max(12, config.segments)

        for index in 0...segments {
            let angle = (Float(index) / Float(segments)) * 2.0 * .pi
            let cosAngle = cos(angle)
            let sinAngle = sin(angle)

            let inner = SIMD3<Float>(
                innerRadius * cosAngle,
                config.floorY,
                config.centerZ + innerRadius * sinAngle
            )

            let outer = SIMD3<Float>(
                outerRadius * cosAngle,
                config.floorY,
                config.centerZ + outerRadius * sinAngle
            )

            positions.append(inner)
            positions.append(outer)

            textureCoordinates.append(
                equirectangularUV(
                    forPoint: inner,
                    config: config
                )
            )

            textureCoordinates.append(
                equirectangularUV(
                    forPoint: outer,
                    config: config
                )
            )
        }

        for index in 0..<segments {
            let i0 = UInt32(index * 2)
            let i1 = UInt32(index * 2 + 1)
            let i2 = UInt32(index * 2 + 2)
            let i3 = UInt32(index * 2 + 3)

            indices.append(contentsOf: [i0, i1, i2])
            indices.append(contentsOf: [i2, i1, i3])
            indices.append(contentsOf: [i2, i1, i0])
            indices.append(contentsOf: [i3, i1, i2])
        }

        var descriptor = MeshDescriptor(name: "ProjectedHDRIGroundAnnulus")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(textureCoordinates)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(
            from: [descriptor]
        )
    }

    static func equirectangularUV(
        forPoint point: SIMD3<Float>,
        config: Config
    ) -> SIMD2<Float> {
        var direction = point - config.projectionOrigin

        if simd_length(direction) < 0.0001 {
            direction = SIMD3<Float>(0, -1, 0)
        } else {
            direction = simd_normalize(direction)
        }

        let yaw = atan2(direction.x, -direction.z) + config.yawOffsetRadians
        var u = 0.5 + yaw / (2.0 * .pi)

        while u < 0 { u += 1 }
        while u > 1 { u -= 1 }

        let v = acos(max(-1, min(1, direction.y))) / .pi

        return SIMD2<Float>(u, v)
    }
}
