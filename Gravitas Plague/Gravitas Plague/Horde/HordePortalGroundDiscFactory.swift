import RealityKit
import UIKit
import simd

enum HordePortalGroundDiscFactory {
    struct Config {
        var floorY: Float
        var centerZ: Float
        var radius: Float
        var segments: Int = 96
        var featherRingCount: Int = 8
        var featherStartFraction: Float = 0.72
        var exposure: Float = 1.0
    }

    @MainActor
    static func makeGroundDisc(
        config: Config
    ) throws -> Entity {
        let texture = try TextureResource.load(
            named: "hellscape_groundplane"
        )

        let root = Entity()
        root.name = "HordeHellscapeGroundDiscRoot"

        let innerRadius = config.radius * config.featherStartFraction
        let core = try makeDiscEntity(
            texture: texture,
            innerRadius: 0,
            outerRadius: innerRadius,
            alpha: 1.0,
            config: config,
            name: "HordeHellscapeGroundDisc_Core"
        )

        root.addChild(core)

        for ring in 0..<config.featherRingCount {
            let t0 = Float(ring) / Float(config.featherRingCount)
            let t1 = Float(ring + 1) / Float(config.featherRingCount)
            let r0 = innerRadius + (config.radius - innerRadius) * t0
            let r1 = innerRadius + (config.radius - innerRadius) * t1
            let alpha = pow(1.0 - t0, 1.85) * 0.82

            let feather = try makeDiscEntity(
                texture: texture,
                innerRadius: r0,
                outerRadius: r1,
                alpha: alpha,
                config: config,
                name: "HordeHellscapeGroundDisc_Feather_\(ring)"
            )

            root.addChild(feather)
        }

        print(
            """
            [HordePortalGroundDisc] PNG ground disc created
              texture: hellscape_groundplane.png
              floorY: \(config.floorY)
              centerZ: \(config.centerZ)
              radius: \(config.radius)
              featherRings: \(config.featherRingCount)
            """
        )

        return root
    }
}

private extension HordePortalGroundDiscFactory {
    static func makeDiscEntity(
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
            opacity: .init(floatLiteral: alpha)
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
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let segments = max(
            16,
            config.segments
        )

        for i in 0...segments {
            let angle = Float(i) / Float(segments) * 2.0 * .pi
            let cosA = cos(angle)
            let sinA = sin(angle)
            let inner = SIMD3<Float>(
                innerRadius * cosA,
                config.floorY,
                config.centerZ + innerRadius * sinA
            )
            let outer = SIMD3<Float>(
                outerRadius * cosA,
                config.floorY,
                config.centerZ + outerRadius * sinA
            )

            positions.append(inner)
            positions.append(outer)
            uvs.append(
                planarUV(
                    point: inner,
                    centerZ: config.centerZ,
                    radius: config.radius
                )
            )
            uvs.append(
                planarUV(
                    point: outer,
                    centerZ: config.centerZ,
                    radius: config.radius
                )
            )
        }

        for i in 0..<segments {
            let i0 = UInt32(i * 2)
            let i1 = UInt32(i * 2 + 1)
            let i2 = UInt32(i * 2 + 2)
            let i3 = UInt32(i * 2 + 3)

            indices.append(contentsOf: [i0, i1, i2])
            indices.append(contentsOf: [i2, i1, i3])
            indices.append(contentsOf: [i2, i1, i0])
            indices.append(contentsOf: [i3, i1, i2])
        }

        var descriptor = MeshDescriptor(
            name: "HordeHellscapeGroundAnnulus"
        )
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(
            from: [descriptor]
        )
    }

    static func planarUV(
        point: SIMD3<Float>,
        centerZ: Float,
        radius: Float
    ) -> SIMD2<Float> {
        let denominator = max(
            radius * 2.0,
            0.001
        )
        let u = 0.5 + point.x / denominator
        let v = 0.5 + (point.z - centerZ) / denominator

        return SIMD2<Float>(
            max(0, min(1, u)),
            max(0, min(1, v))
        )
    }
}
