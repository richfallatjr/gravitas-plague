import RealityKit
import UIKit
import simd

enum HordePortalApertureMeshFactory {
    static func makePortalPlane(
        profile: HordePortalApertureProfile,
        targetWorld: Entity
    ) throws -> ModelEntity {
        let mesh = try makeFilledApertureMesh(
            profile: profile
        )

        let portal = ModelEntity(
            mesh: mesh,
            materials: [PortalMaterial()]
        )

        portal.name = "HordeJankyPortalAperture"
        portal.position.z = -0.006
        portal.components.set(
            PortalComponent(
                target: targetWorld
            )
        )

        return portal
    }

    static func makeFilledApertureMesh(
        profile: HordePortalApertureProfile
    ) throws -> MeshResource {
        let boundary = makeBoundary(
            profile: profile
        )

        let center = boundary.reduce(SIMD2<Float>(0, 0), +) / Float(boundary.count)

        var positions: [SIMD3<Float>] = [
            SIMD3<Float>(center.x, center.y, 0)
        ]

        for point in boundary {
            positions.append(
                SIMD3<Float>(
                    point.x,
                    point.y,
                    0
                )
            )
        }

        var indices: [UInt32] = []

        for index in 0..<boundary.count {
            let next = (index + 1) % boundary.count
            indices.append(0)
            indices.append(UInt32(index + 1))
            indices.append(UInt32(next + 1))
        }

        var descriptor = MeshDescriptor(
            name: "HordeJankyPortalAperture"
        )
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(
            from: [descriptor]
        )
    }

    static func makeBoundary(
        profile: HordePortalApertureProfile
    ) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []

        points.append(profile.leftBottom)
        points.append(profile.rightBottom)
        points.append(profile.rightTop)

        let samples = max(
            3,
            profile.topSamples
        )

        for index in 1..<(samples - 1) {
            let t = Float(index) / Float(samples - 1)
            let x = lerp(
                profile.rightTop.x,
                profile.leftTop.x,
                t
            )
            let baseY = lerp(
                profile.rightTop.y,
                profile.leftTop.y,
                t
            )
            let arc = sin(t * .pi)
            let asymmetry = sin(t * .pi * 2.0)
            let y =
                baseY +
                arc * profile.topPeakOffset +
                asymmetry * profile.topSagOffset

            points.append(
                SIMD2<Float>(
                    x,
                    y
                )
            )
        }

        points.append(profile.leftTop)

        return points
    }

    private static func lerp(
        _ a: Float,
        _ b: Float,
        _ t: Float
    ) -> Float {
        a + (b - a) * t
    }
}

enum HordePortalSoftWallFeatherFactory {
    static let enabled = true

    static func makeFeather(
        profile: HordePortalApertureProfile,
        seed: UInt64
    ) throws -> Entity {
        let root = Entity()
        root.name = "HordePortalSoftWallFeather"

        let layers: [(expansion: Float, alpha: Float, color: UIColor)] = [
            (
                0.06,
                0.38,
                UIColor(
                    red: 0.50,
                    green: 0.02,
                    blue: 0.00,
                    alpha: 1.0
                )
            ),
            (
                0.12,
                0.22,
                UIColor(
                    red: 0.10,
                    green: 0.00,
                    blue: 0.00,
                    alpha: 1.0
                )
            ),
            (
                0.20,
                0.10,
                UIColor(
                    red: 0.02,
                    green: 0.00,
                    blue: 0.00,
                    alpha: 1.0
                )
            )
        ]

        for (index, layer) in layers.enumerated() {
            let mesh = try makeFeatherRingMesh(
                profile: profile,
                expansion: layer.expansion,
                seed: seed &+ UInt64(index * 977)
            )

            var material = UnlitMaterial()
            material.color = .init(
                tint: layer.color.withAlphaComponent(
                    CGFloat(layer.alpha)
                )
            )
            material.blending = .transparent(
                opacity: .init(floatLiteral: layer.alpha)
            )
            material.faceCulling = .none

            let entity = ModelEntity(
                mesh: mesh,
                materials: [material]
            )

            entity.name = "HordePortalSoftWallFeatherLayer_\(index)"
            entity.position.z = 0.004 + Float(index) * 0.001
            root.addChild(entity)
        }

        print("[HordePortal] soft wall feather created, no hard frame")

        return root
    }

    private static func makeFeatherRingMesh(
        profile: HordePortalApertureProfile,
        expansion: Float,
        seed: UInt64
    ) throws -> MeshResource {
        var rng = SeededRNG(seed: seed)
        let inner = HordePortalApertureMeshFactory.makeBoundary(
            profile: profile
        )
        let center = inner.reduce(SIMD2<Float>(0, 0), +) / Float(inner.count)

        var outer: [SIMD2<Float>] = []

        for point in inner {
            var direction = point - center

            if simd_length(direction) < 0.001 {
                direction = SIMD2<Float>(0, 1)
            } else {
                direction = simd_normalize(direction)
            }

            let amount = expansion * Float.random(in: 0.65...1.35, using: &rng)
            let isBottom = abs(point.y - profile.bottomY) < 0.001
            var outerPoint = point + direction * amount

            if isBottom {
                outerPoint.y = profile.bottomY
            }

            outer.append(outerPoint)
        }

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for index in inner.indices {
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

        for index in inner.indices {
            let next = (index + 1) % inner.count
            let i0 = UInt32(index * 2)
            let i1 = UInt32(index * 2 + 1)
            let i2 = UInt32(next * 2)
            let i3 = UInt32(next * 2 + 1)

            indices.append(contentsOf: [i0, i1, i2])
            indices.append(contentsOf: [i2, i1, i3])
        }

        var descriptor = MeshDescriptor(
            name: "HordePortalSoftWallFeatherRing"
        )
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(
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
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

