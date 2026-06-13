import RealityKit
import simd
import UIKit

enum DimensionalTearPortalRimFactory {
    static func makeRim(
        width: Float,
        height: Float,
        seed: UInt64
    ) -> Entity {
        let root = Entity()
        root.name = "DimensionalTearPortalRim"

        let layers: [(Float, Float, UIColor, String)] = [
            (
                0.035,
                0.85,
                UIColor(red: 0.04, green: 0.00, blue: 0.00, alpha: 0.75),
                "inner_dark_bleed"
            ),
            (
                0.075,
                0.55,
                UIColor(red: 0.55, green: 0.04, blue: 0.00, alpha: 0.55),
                "red_hot_rift"
            ),
            (
                0.135,
                0.26,
                UIColor(red: 0.02, green: 0.00, blue: 0.00, alpha: 0.38),
                "outer_smoke_feather"
            )
        ]

        for (index, layer) in layers.enumerated() {
            let entity = makeRaggedRectRing(
                width: width + layer.0,
                height: height + layer.0,
                thickness: layer.0,
                alpha: layer.1,
                color: layer.2,
                seed: seed &+ UInt64(index * 7919),
                name: layer.3
            )

            root.addChild(entity)
        }

        root.position.z = 0.012

        print(
            """
            [HordePortalRim] dimensional tear rim created
              width: \(width)
              height: \(height)
              frameStyle: feathered_rift_not_door_frame
            """
        )

        return root
    }
}

private extension DimensionalTearPortalRimFactory {
    static func makeRaggedRectRing(
        width: Float,
        height: Float,
        thickness: Float,
        alpha: Float,
        color: UIColor,
        seed: UInt64,
        name: String
    ) -> ModelEntity {
        let mesh = makeRaggedRectRingMesh(
            width: width,
            height: height,
            thickness: thickness,
            seed: seed
        )

        var material = UnlitMaterial()
        material.color = .init(
            tint: color.withAlphaComponent(CGFloat(alpha))
        )
        material.blending = .transparent(
            opacity: .init(floatLiteral: max(0.001, alpha))
        )
        material.faceCulling = .none

        let entity = ModelEntity(
            mesh: mesh,
            materials: [material]
        )

        entity.name = "DimensionalTear_\(name)"
        entity.position.z = 0.018

        return entity
    }

    static func makeRaggedRectRingMesh(
        width: Float,
        height: Float,
        thickness: Float,
        seed: UInt64
    ) -> MeshResource {
        var rng = SeededRNG(seed: seed)
        let pointsPerSide = 18

        func jitter(
            _ amount: Float
        ) -> Float {
            Float.random(
                in: -amount...amount,
                using: &rng
            )
        }

        var inner: [SIMD2<Float>] = []
        var outer: [SIMD2<Float>] = []

        func appendPoint(
            _ point: SIMD2<Float>,
            normal: SIMD2<Float>
        ) {
            let innerJitter = jitter(thickness * 0.32)
            let outerJitter = abs(jitter(thickness * 0.55))

            inner.append(point + normal * innerJitter)
            outer.append(point + normal * (thickness + outerJitter))
        }

        let halfWidth = width * 0.5
        let halfHeight = height * 0.5

        for index in 0..<pointsPerSide {
            let t = Float(index) / Float(pointsPerSide - 1)
            appendPoint(
                SIMD2<Float>(
                    -halfWidth + width * t,
                    halfHeight
                ),
                normal: SIMD2<Float>(0, 1)
            )
        }

        for index in 0..<pointsPerSide {
            let t = Float(index) / Float(pointsPerSide - 1)
            appendPoint(
                SIMD2<Float>(
                    halfWidth,
                    halfHeight - height * t
                ),
                normal: SIMD2<Float>(1, 0)
            )
        }

        for index in 0..<pointsPerSide {
            let t = Float(index) / Float(pointsPerSide - 1)
            appendPoint(
                SIMD2<Float>(
                    halfWidth - width * t,
                    -halfHeight
                ),
                normal: SIMD2<Float>(0, -1)
            )
        }

        for index in 0..<pointsPerSide {
            let t = Float(index) / Float(pointsPerSide - 1)
            appendPoint(
                SIMD2<Float>(
                    -halfWidth,
                    -halfHeight + height * t
                ),
                normal: SIMD2<Float>(-1, 0)
            )
        }

        let count = inner.count

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for index in 0..<count {
            positions.append(
                SIMD3<Float>(
                    inner[index].x,
                    inner[index].y,
                    0
                )
            )
            positions.append(
                SIMD3<Float>(
                    outer[index].x,
                    outer[index].y,
                    0
                )
            )
        }

        for index in 0..<count {
            let next = (index + 1) % count

            let i0 = UInt32(index * 2)
            let i1 = UInt32(index * 2 + 1)
            let i2 = UInt32(next * 2)
            let i3 = UInt32(next * 2 + 1)

            indices.append(contentsOf: [i0, i1, i2])
            indices.append(contentsOf: [i2, i1, i3])
            indices.append(contentsOf: [i2, i1, i0])
            indices.append(contentsOf: [i3, i1, i2])
        }

        var descriptor = MeshDescriptor(name: "DimensionalTearRaggedRing")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)

        return try! MeshResource.generate(
            from: [descriptor]
        )
    }
}

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x123456789ABCDEF : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
