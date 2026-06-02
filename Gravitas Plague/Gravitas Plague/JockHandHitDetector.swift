import ARKit
import Foundation
import RealityKit
import simd

@MainActor
final class JockHandHitDetector {
    struct HandSample {
        let position: SIMD3<Float>
        let time: TimeInterval
    }

    struct HitEvent: Equatable {
        let side: JockHitSide
        let damageLevel: JockHitDamageLevel
        let hand: HandAnchor.Chirality
        let position: SIMD3<Float>
        let velocityMetersPerSecond: Float
    }

    private let configuration: JockHitReactionConfiguration

    private let arkitSession = ARKitSession()
    private let handTrackingProvider = HandTrackingProvider()

    private var isRunning = false

    private var previousSamples: [HandAnchor.Chirality: HandSample] = [:]
    private var perHandLastHitTime: [HandAnchor.Chirality: TimeInterval] = [:]
    private var globalLastHitTime: TimeInterval = -999

    init(configuration: JockHitReactionConfiguration) {
        self.configuration = configuration
    }

    func startIfNeeded() async {
        guard configuration.enabled else { return }
        guard !isRunning else { return }

        guard HandTrackingProvider.isSupported else {
            print("[Gravitas Hit] HandTrackingProvider is not supported on this device.")
            return
        }

        do {
            try await arkitSession.run([handTrackingProvider])
            isRunning = true
            print("[Gravitas Hit] HandTrackingProvider started.")
        } catch {
            print("[Gravitas Hit] Failed to start hand tracking: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }

        arkitSession.stop()
        isRunning = false
        previousSamples.removeAll()
        perHandLastHitTime.removeAll()
        globalLastHitTime = -999

        print("[Gravitas Hit] Hand tracking stopped.")
    }

    func update(
        currentTime: TimeInterval,
        characterRoot: Entity,
        faceCenterWorld: SIMD3<Float>
    ) -> HitEvent? {
        guard configuration.enabled else { return nil }
        guard isRunning else { return nil }

        let left = evaluateHand(
            chirality: .left,
            currentTime: currentTime,
            characterRoot: characterRoot,
            faceCenterWorld: faceCenterWorld
        )

        let right = evaluateHand(
            chirality: .right,
            currentTime: currentTime,
            characterRoot: characterRoot,
            faceCenterWorld: faceCenterWorld
        )

        switch (left, right) {
        case (.some(let leftEvent), .some(let rightEvent)):
            return leftEvent.velocityMetersPerSecond >= rightEvent.velocityMetersPerSecond
                ? leftEvent
                : rightEvent

        case (.some(let event), .none):
            return event

        case (.none, .some(let event)):
            return event

        case (.none, .none):
            return nil
        }
    }

    private func evaluateHand(
        chirality: HandAnchor.Chirality,
        currentTime: TimeInterval,
        characterRoot: Entity,
        faceCenterWorld: SIMD3<Float>
    ) -> HitEvent? {
        guard let handAnchor = latestHandAnchor(chirality: chirality) else {
            return nil
        }

        guard let handPosition = preferredStrikePosition(from: handAnchor) else {
            return nil
        }

        defer {
            previousSamples[chirality] = HandSample(
                position: handPosition,
                time: currentTime
            )
        }

        guard let previous = previousSamples[chirality] else {
            return nil
        }

        let dt = max(currentTime - previous.time, 0.0001)
        let velocityVector = (handPosition - previous.position) / Float(dt)
        let speed = simd_length(velocityVector)

        guard let damage = configuration.damageLevel(for: speed) else {
            return nil
        }

        if currentTime - globalLastHitTime < configuration.globalHitCooldownSeconds {
            return nil
        }

        if let last = perHandLastHitTime[chirality],
           currentTime - last < configuration.perHandCooldownSeconds {
            return nil
        }

        let zones = faceZones(
            characterRoot: characterRoot,
            faceCenterWorld: faceCenterWorld
        )

        let leftDistance = simd_distance(handPosition, zones.left)
        let rightDistance = simd_distance(handPosition, zones.right)

        let side: JockHitSide
        let target: SIMD3<Float>
        let distance: Float

        if leftDistance <= rightDistance {
            side = .left
            target = zones.left
            distance = leftDistance
        } else {
            side = .right
            target = zones.right
            distance = rightDistance
        }

        guard distance <= configuration.maxHitDistanceMeters else {
            return nil
        }

        let towardFace = PhaseOneMath.normalizedOrFallback(
            target - previous.position,
            fallback: SIMD3<Float>(0, 0, 0)
        )

        let velocityDirection = speed > 0.0001
            ? simd_normalize(velocityVector)
            : SIMD3<Float>(0, 0, 0)

        let approachDot = simd_dot(velocityDirection, towardFace)

        guard approachDot > 0.12 else {
            return nil
        }

        globalLastHitTime = currentTime
        perHandLastHitTime[chirality] = currentTime

        return HitEvent(
            side: side,
            damageLevel: damage,
            hand: chirality,
            position: handPosition,
            velocityMetersPerSecond: speed
        )
    }

    private func latestHandAnchor(
        chirality: HandAnchor.Chirality
    ) -> HandAnchor? {
        let anchors = handTrackingProvider.latestAnchors

        switch chirality {
        case .left:
            return anchors.leftHand

        case .right:
            return anchors.rightHand

        @unknown default:
            return nil
        }
    }

    private func preferredStrikePosition(
        from handAnchor: HandAnchor
    ) -> SIMD3<Float>? {
        guard handAnchor.isTracked else {
            return nil
        }

        guard let skeleton = handAnchor.handSkeleton else {
            return nil
        }

        let candidateJointNames: [HandSkeleton.JointName] = [
            .middleFingerMetacarpal,
            .indexFingerMetacarpal,
            .wrist,
            .indexFingerTip
        ]

        for jointName in candidateJointNames {
            let joint = skeleton.joint(jointName)

            guard joint.isTracked else {
                continue
            }

            let jointWorldTransform =
                handAnchor.originFromAnchorTransform *
                joint.anchorFromJointTransform

            return SIMD3<Float>(
                jointWorldTransform.columns.3.x,
                jointWorldTransform.columns.3.y,
                jointWorldTransform.columns.3.z
            )
        }

        return nil
    }

    private func faceZones(
        characterRoot: Entity,
        faceCenterWorld: SIMD3<Float>
    ) -> (left: SIMD3<Float>, right: SIMD3<Float>) {
        let rightVector = characterRoot.orientation.act(
            SIMD3<Float>(1, 0, 0)
        )

        let horizontalRight = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(rightVector.x, 0, rightVector.z),
            fallback: SIMD3<Float>(1, 0, 0)
        )

        let offset = horizontalRight * configuration.faceSideOffsetMeters

        return (
            left: faceCenterWorld + offset,
            right: faceCenterWorld - offset
        )
    }
}
