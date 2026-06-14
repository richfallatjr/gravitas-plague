import RealityKit
import UIKit
import simd

@MainActor
enum HordePortalGroundDiscFactory {
    struct Config {
        var floorY: Float
        var centerZ: Float
        var radius: Float
        var segments: Int = 96
        var featherRingCount: Int = 8
        var featherStartFraction: Float = 0.72
        var textureName: String = "hellscape_groundplane"
        var exposure: Float = 1.0
    }

    static func makeGroundDisc(
        config: Config
    ) throws -> Entity {
        let texture = try TextureResource.load(
            named: config.textureName
        )

        let root = Entity()
        root.name = "HordePortalGroundDiscRoot"

        let innerRadius = config.radius * config.featherStartFraction

        let core = try makeDiscEntity(
            texture: texture,
            innerRadius: 0,
            outerRadius: innerRadius,
            alpha: 1.0,
            config: config,
            name: "HordePortalGroundDisc_Core"
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
                name: "HordePortalGroundDisc_Feather_\(ring)"
            )

            root.addChild(feather)
        }

        print(
            """
            [HordePortalGroundDisc] faded disc created
              texture: \(config.textureName).png
              floorY: \(config.floorY)
              centerZ: \(config.centerZ)
              radius: \(config.radius)
              featherStartFraction: \(config.featherStartFraction)
              featherRingCount: \(config.featherRingCount)
              geometry: circular_disc_with_faded_edge
              placementSource: committed_portal_context
              plane: portal_local_xz
              flatConstantY: true
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
        let mesh: MeshResource

        if innerRadius <= 0.0001 {
            mesh = try makeFilledDiscMesh(
                radius: outerRadius,
                config: config
            )
        } else {
            mesh = try makeAnnulusMesh(
                innerRadius: innerRadius,
                outerRadius: outerRadius,
                config: config
            )
        }

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

    static func makeFilledDiscMesh(
        radius: Float,
        config: Config
    ) throws -> MeshResource {
        let segments = max(
            16,
            config.segments
        )

        var positions: [SIMD3<Float>] = [
            SIMD3<Float>(
                0,
                config.floorY,
                config.centerZ
            )
        ]
        var uvs: [SIMD2<Float>] = [
            SIMD2<Float>(0.5, 0.5)
        ]
        var indices: [UInt32] = []

        for index in 0...segments {
            let angle = Float(index) / Float(segments) * 2.0 * .pi
            let x = cos(angle) * radius
            let z = sin(angle) * radius

            positions.append(
                SIMD3<Float>(
                    x,
                    config.floorY,
                    config.centerZ + z
                )
            )
            uvs.append(
                planarUV(
                    x: x,
                    z: z,
                    radius: config.radius
                )
            )
        }

        for index in 1...segments {
            let i0: UInt32 = 0
            let i1 = UInt32(index)
            let i2 = UInt32(index + 1)

            indices.append(contentsOf: [
                i0, i1, i2,
                i2, i1, i0
            ])
        }

        var descriptor = MeshDescriptor(
            name: "HordePortalGroundFilledDisc"
        )
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(
            from: [descriptor]
        )
    }

    static func makeAnnulusMesh(
        innerRadius: Float,
        outerRadius: Float,
        config: Config
    ) throws -> MeshResource {
        let segments = max(
            16,
            config.segments
        )

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for index in 0...segments {
            let angle = Float(index) / Float(segments) * 2.0 * .pi
            let cosA = cos(angle)
            let sinA = sin(angle)

            let innerX = innerRadius * cosA
            let innerZ = innerRadius * sinA
            let outerX = outerRadius * cosA
            let outerZ = outerRadius * sinA

            positions.append(
                SIMD3<Float>(
                    innerX,
                    config.floorY,
                    config.centerZ + innerZ
                )
            )
            positions.append(
                SIMD3<Float>(
                    outerX,
                    config.floorY,
                    config.centerZ + outerZ
                )
            )
            uvs.append(
                planarUV(
                    x: innerX,
                    z: innerZ,
                    radius: config.radius
                )
            )
            uvs.append(
                planarUV(
                    x: outerX,
                    z: outerZ,
                    radius: config.radius
                )
            )
        }

        for index in 0..<segments {
            let i0 = UInt32(index * 2)
            let i1 = UInt32(index * 2 + 1)
            let i2 = UInt32(index * 2 + 2)
            let i3 = UInt32(index * 2 + 3)

            indices.append(contentsOf: [
                i0, i1, i2,
                i2, i1, i3,
                i2, i1, i0,
                i3, i1, i2
            ])
        }

        var descriptor = MeshDescriptor(
            name: "HordePortalGroundAnnulus"
        )
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(
            from: [descriptor]
        )
    }

    static func planarUV(
        x: Float,
        z: Float,
        radius: Float
    ) -> SIMD2<Float> {
        let denominator = max(
            radius * 2.0,
            0.001
        )

        return SIMD2<Float>(
            max(0, min(1, 0.5 + x / denominator)),
            max(0, min(1, 0.5 + z / denominator))
        )
    }
}
