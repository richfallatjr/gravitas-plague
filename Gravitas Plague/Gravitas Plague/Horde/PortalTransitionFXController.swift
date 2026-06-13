import Foundation
import RealityKit
import UIKit
import simd

struct PortalFXSegment {
    let index: Int
    let a: SIMD3<Float>
    let b: SIMD3<Float>
    let midpoint: SIMD3<Float>
    let direction: SIMD3<Float>
    let length: Float
    let isBottom: Bool
    let birthRate: Float
}

@MainActor
final class PortalTransitionFXController {
    let rootEntity = Entity()

    private var tubeRoot = Entity()
    private var emberRoot = Entity()

    private var perimeterLocalPoints: [SIMD3<Float>]
    private let portalNormalLocal: SIMD3<Float>

    private var segments: [PortalFXSegment] = []

    private var tubeEntities: [Entity] = []
    private var jointEntities: [Entity] = []

    private var emberPool: PortalEmberPool?
    private var emissionAccumulator: Float = 0

    private var enabled: Bool = true

    init(
        perimeterLocalPoints: [SIMD3<Float>],
        portalNormalLocal: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    ) {
        self.perimeterLocalPoints = perimeterLocalPoints
        self.portalNormalLocal = portalFXNormalizeSafe(
            portalNormalLocal,
            fallback: SIMD3<Float>(0, 0, 1)
        )

        rootEntity.name = "PortalTransitionFXRoot"
        tubeRoot.name = "PortalTransitionTubeRoot"
        emberRoot.name = "PortalTransitionEmberRoot"

        rootEntity.addChild(tubeRoot)
        rootEntity.addChild(emberRoot)
    }

    func build() {
        teardownGeometryOnly()

        if tubeRoot.parent == nil {
            rootEntity.addChild(tubeRoot)
        }

        if emberRoot.parent == nil {
            rootEntity.addChild(emberRoot)
        }

        segments = buildSegments(
            points: perimeterLocalPoints
        )

        buildTube()
        buildJoints()

        let maxActive = Int(
            ceil(
                PortalFXDefaults.emberBirthRatePerDoor *
                PortalFXDefaults.emberLifeSecondsMax *
                PortalFXDefaults.emberMaxActiveMultiplier
            )
        )

        emberPool = PortalEmberPool(
            root: emberRoot,
            maxActive: maxActive
        )

        PlagueNativeBloomInstaller.installOnEntity(
            rootEntity,
            label: "portal_transition_fx"
        )

        let bottomSegments = segments.filter(\.isBottom)
        let bottomBirthRate = bottomSegments.reduce(Float(0)) {
            $0 + $1.birthRate
        }

        for segment in bottomSegments {
            let sample = makeSpawnSample(
                segment: segment
            )
            let velocityDirection = portalFXNormalizeSafe(
                sample.velocity,
                fallback: SIMD3<Float>(0, 1, 0)
            )

            if velocityDirection.y < 0.35 {
                print(
                    """
                    [PortalFX] ERROR bottom ember velocity not upward enough
                      segment: \(segment.index)
                      velocityDir: \(velocityDirection)
                    """
                )
            }

            if abs(velocityDirection.z) > PortalFXDefaults.maxNormalVelocityLeak * 2.5 {
                print(
                    """
                    [PortalFX] ERROR bottom ember has too much wall-normal velocity
                      segment: \(segment.index)
                      velocityDir: \(velocityDirection)
                    """
                )
            }
        }

        print(
            """
            [PortalFX] ember density tuned
              birthRatePerDoor: \(PortalFXDefaults.emberBirthRatePerDoor)
              oldBirthRateWas: 1000
              densityReduction: \(1000.0 / PortalFXDefaults.emberBirthRatePerDoor)x
              maxActivePool: \(maxActive)
            """
        )

        print(
            """
            [PortalFX] built
              perimeterPoints: \(perimeterLocalPoints.count)
              segments: \(segments.count)
              tubeRadius: \(PortalFXDefaults.tubeRadiusMeters)
              tubeThicknessReduction: 4x
              tubeEmissiveIntensity: \(PortalFXDefaults.tubeEmissiveIntensity)
              emberRatePerDoor: \(PortalFXDefaults.emberBirthRatePerDoor)
              densityReductionFrom1000: \(1000.0 / PortalFXDefaults.emberBirthRatePerDoor)x
              emberSpeedRange: \(PortalFXDefaults.emberSpeedMetersPerSecondMin)-\(PortalFXDefaults.emberSpeedMetersPerSecondMax)
              emberLifeRange: \(PortalFXDefaults.emberLifeSecondsMin)-\(PortalFXDefaults.emberLifeSecondsMax)
              emberDirection: wall_parallel
              bottomEmissionRule: upward_only
            """
        )

        print(
            """
            [PortalFX] bottom emission audit
              bottomSegmentCount: \(bottomSegments.count)
              bottomBirthRate: \(bottomBirthRate)
              allowedOnlyIfUpward: true
              bottomParticlesFlowUpward: true
              wallParallel: true
            """
        )
    }

    func update(
        deltaTime: Float
    ) {
        guard enabled else {
            return
        }

        emit(
            deltaTime: deltaTime
        )
        emberPool?.update(
            deltaTime: deltaTime
        )
    }

    func setEnabled(
        _ enabled: Bool
    ) {
        self.enabled = enabled
        rootEntity.isEnabled = enabled
        emberPool?.setEnabled(enabled)

        print(
            """
            [PortalFX] enabled changed
              enabled: \(enabled)
            """
        )
    }

    func updatePerimeter(
        _ points: [SIMD3<Float>]
    ) {
        perimeterLocalPoints = points
        build()
    }

    func teardown() {
        emberPool?.teardown()
        emberPool = nil
        teardownGeometryOnly()
        rootEntity.removeFromParent()

        print("[PortalFX] torn down")
    }

    private func teardownGeometryOnly() {
        tubeRoot.children.removeAll()
        emberRoot.children.removeAll()

        tubeEntities.removeAll()
        jointEntities.removeAll()
        segments.removeAll()
        emissionAccumulator = 0
    }
}

private extension PortalTransitionFXController {
    func buildSegments(
        points: [SIMD3<Float>]
    ) -> [PortalFXSegment] {
        guard points.count >= 2 else {
            return []
        }

        var closedPoints = points

        if let first = points.first,
           let last = points.last,
           simd_distance(first, last) > 0.001 {
            closedPoints.append(first)
        }

        let bottomY = closedPoints.map(\.y).min() ?? 0
        let bottomEpsilon: Float = 0.025

        var rawSegments: [PortalFXSegment] = []

        for index in 0..<(closedPoints.count - 1) {
            let a = closedPoints[index]
            let b = closedPoints[index + 1]
            let delta = b - a
            let length = simd_length(delta)

            guard length > 0.0001 else {
                continue
            }

            let midpoint = (a + b) * 0.5
            let direction = delta / length

            let isBottom =
                abs(a.y - bottomY) < bottomEpsilon &&
                abs(b.y - bottomY) < bottomEpsilon

            rawSegments.append(
                PortalFXSegment(
                    index: index,
                    a: a,
                    b: b,
                    midpoint: midpoint,
                    direction: direction,
                    length: length,
                    isBottom: isBottom,
                    birthRate: 0
                )
            )
        }

        let totalWeightedLength = rawSegments.reduce(Float(0)) { sum, segment in
            let multiplier = segment.isBottom
                ? PortalFXDefaults.bottomSegmentBirthRateMultiplier
                : 1.0

            return sum + segment.length * multiplier
        }

        let safeTotal = max(
            totalWeightedLength,
            0.001
        )

        return rawSegments.map { segment in
            let multiplier = segment.isBottom
                ? PortalFXDefaults.bottomSegmentBirthRateMultiplier
                : 1.0

            let rate =
                PortalFXDefaults.emberBirthRatePerDoor *
                (segment.length * multiplier / safeTotal)

            return PortalFXSegment(
                index: segment.index,
                a: segment.a,
                b: segment.b,
                midpoint: segment.midpoint,
                direction: segment.direction,
                length: segment.length,
                isBottom: segment.isBottom,
                birthRate: rate
            )
        }
    }
}

private extension PortalTransitionFXController {
    func buildTube() {
        let material = PortalFXSharedResources.shared.tubeMaterial

        for segment in segments {
            let mesh = MeshResource.generateCylinder(
                height: segment.length,
                radius: PortalFXDefaults.tubeRadiusMeters
            )

            let entity = ModelEntity(
                mesh: mesh,
                materials: [material]
            )

            entity.name = "PortalFX_TubeSegment_\(segment.index)"
            entity.position = segment.midpoint
            entity.orientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: segment.direction
            )

            tubeRoot.addChild(entity)
            tubeEntities.append(entity)
        }

        print(
            """
            [PortalFX] emissive tube built
              segments: \(segments.count)
              snappedToPortalPerimeter: true
            """
        )
    }

    func buildJoints() {
        let material = PortalFXSharedResources.shared.jointMaterial

        var uniquePoints: [SIMD3<Float>] = []

        for segment in segments {
            uniquePoints.append(segment.a)
        }

        for (index, point) in uniquePoints.enumerated() {
            let mesh = MeshResource.generateSphere(
                radius: PortalFXDefaults.tubeJointRadiusMeters
            )

            let entity = ModelEntity(
                mesh: mesh,
                materials: [material]
            )

            entity.name = "PortalFX_TubeJoint_\(index)"
            entity.position = point

            tubeRoot.addChild(entity)
            jointEntities.append(entity)
        }
    }
}

private extension PortalTransitionFXController {
    func emit(
        deltaTime: Float
    ) {
        guard let emberPool,
              !segments.isEmpty else {
            return
        }

        emissionAccumulator += PortalFXDefaults.emberBirthRatePerDoor * deltaTime

        let emitCount = Int(emissionAccumulator)

        guard emitCount > 0 else {
            return
        }

        emissionAccumulator -= Float(emitCount)

        for _ in 0..<emitCount {
            guard let segment = chooseEmissionSegment() else {
                continue
            }

            let spawn = makeSpawnSample(
                segment: segment
            )

            emberPool.spawn(
                position: spawn.position,
                velocity: spawn.velocity,
                life: spawn.life
            )
        }
    }

    func chooseEmissionSegment() -> PortalFXSegment? {
        let totalRate = segments.reduce(Float(0)) {
            $0 + $1.birthRate
        }

        guard totalRate > 0 else {
            return segments.randomElement()
        }

        var pick = Float.random(
            in: 0..<totalRate
        )

        for segment in segments {
            pick -= segment.birthRate

            if pick <= 0 {
                return segment
            }
        }

        return segments.last
    }

    struct SpawnSample {
        let position: SIMD3<Float>
        let velocity: SIMD3<Float>
        let life: Float
    }

    func makeSpawnSample(
        segment: PortalFXSegment
    ) -> SpawnSample {
        let t = Float.random(in: 0...1)
        let base = segment.a + (segment.b - segment.a) * t

        let wallOut = wallPlaneDirectionAwayFromAperture(
            segment: segment
        )

        let tangent = segment.direction
        let tangentJitter = tangent * Float.random(in: -0.30...0.30)

        let upwardJitter = SIMD3<Float>(
            0,
            Float.random(in: 0.00...0.18),
            0
        )

        let normalLeak =
            portalNormalLocal * Float.random(
                in: -PortalFXDefaults.maxNormalVelocityLeak...PortalFXDefaults.maxNormalVelocityLeak
            )

        var direction: SIMD3<Float>

        if segment.isBottom {
            direction = portalFXNormalizeSafe(
                PortalFXDefaults.portalLocalUp +
                    tangentJitter * 0.20 +
                    wallOut * 0.15 +
                    normalLeak,
                fallback: SIMD3<Float>(0, 1, 0)
            )

            if direction.y < 0.35 {
                direction.y = 0.35
                direction.z = max(
                    min(
                        direction.z,
                        PortalFXDefaults.maxNormalVelocityLeak
                    ),
                    -PortalFXDefaults.maxNormalVelocityLeak
                )
                direction = portalFXNormalizeSafe(
                    direction,
                    fallback: SIMD3<Float>(0, 1, 0)
                )
            }
        } else {
            direction = portalFXNormalizeSafe(
                wallOut +
                    tangentJitter +
                    upwardJitter +
                    normalLeak,
                fallback: wallOut
            )

            direction.z = max(
                min(
                    direction.z,
                    PortalFXDefaults.maxNormalVelocityLeak
                ),
                -PortalFXDefaults.maxNormalVelocityLeak
            )

            direction = portalFXNormalizeSafe(
                direction,
                fallback: wallOut
            )
        }

        let speed = Float.random(
            in: PortalFXDefaults.emberSpeedMetersPerSecondMin...PortalFXDefaults.emberSpeedMetersPerSecondMax
        )

        let life = Float.random(
            in: PortalFXDefaults.emberLifeSecondsMin...PortalFXDefaults.emberLifeSecondsMax
        )

        let surfaceOffset = portalNormalLocal * Float.random(in: 0.00...0.012)

        return SpawnSample(
            position: base + surfaceOffset,
            velocity: direction * speed,
            life: life
        )
    }

    func wallPlaneDirectionAwayFromAperture(
        segment: PortalFXSegment
    ) -> SIMD3<Float> {
        let center = apertureCenter()

        var radial = SIMD3<Float>(
            segment.midpoint.x - center.x,
            segment.midpoint.y - center.y,
            0
        )

        if simd_length(radial) < 0.001 {
            radial = PortalFXDefaults.portalLocalUp
        } else {
            radial = simd_normalize(radial)
        }

        return radial
    }

    func apertureCenter() -> SIMD3<Float> {
        guard !perimeterLocalPoints.isEmpty else {
            return .zero
        }

        let sum = perimeterLocalPoints.reduce(SIMD3<Float>.zero) {
            $0 + $1
        }

        return sum / Float(perimeterLocalPoints.count)
    }
}

private func portalFXNormalizeSafe(
    _ vector: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(vector)

    guard length > 0.00001 else {
        return fallback
    }

    return vector / length
}
