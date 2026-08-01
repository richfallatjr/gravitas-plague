import Foundation
import RealityKit
import simd

@MainActor
final class Chapter01RobotApproachController {
    typealias TargetClamp = @MainActor (SIMD3<Float>) -> SIMD3<Float>

    private weak var controller: JockRetargetTestController?
    private weak var spatialProvider: PhaseOneSpatialProvider?
    private var configuration: Chapter01RobotDefinition.Approach?
    private var pendingAuthoredTravel: Float = 0
    private var completion: (() -> Void)?
    private var targetClamp: TargetClamp = { $0 }
    private(set) var isActive = false

    func begin(
        controller: JockRetargetTestController,
        spatialProvider: PhaseOneSpatialProvider,
        walkClipID: String,
        configuration: Chapter01RobotDefinition.Approach,
        targetClamp: @escaping TargetClamp = { $0 },
        completion: @escaping () -> Void
    ) throws {
        self.controller = controller
        self.spatialProvider = spatialProvider
        self.configuration = configuration
        self.targetClamp = targetClamp
        self.completion = completion
        pendingAuthoredTravel = 0
        isActive = true
        try controller.playScriptedWalkLoop(clipID: walkClipID) { [weak self] distance in
            self?.pendingAuthoredTravel += max(0, distance)
        }
    }

    func update(deltaTime: TimeInterval) {
        guard isActive,
              let controller,
              let spatialProvider,
              let configuration,
              let pose = spatialProvider.currentPose() else { return }

        var horizontalForward = SIMD3<Float>(pose.headForward.x, 0, pose.headForward.z)
        horizontalForward = PhaseOneMath.normalizedOrFallback(
            horizontalForward,
            fallback: SIMD3<Float>(0, 0, -1)
        )
        var desired = Self.desiredTarget(
            headPosition: pose.headPosition,
            headForward: horizontalForward,
            floorY: controller.rootEntity.position(relativeTo: nil).y,
            stopDistanceMeters: configuration.stopDistanceMeters
        )
        desired = targetClamp(desired)

        let current = controller.rootEntity.position(relativeTo: nil)
        var delta = desired - current
        delta.y = 0
        let distance = simd_length(delta)
        if distance <= configuration.arrivalToleranceMeters {
            controller.stopScriptedLocomotion(reason: "chapter01RobotApproachArrived")
            controller.setOrientationYawOnlyFacingPlayer(pose.headPosition)
            finish()
            return
        }

        let direction = delta / max(distance, 0.0001)
        let travel = min(distance, pendingAuthoredTravel)
        pendingAuthoredTravel -= travel
        if travel > 0 {
            var next = current + direction * travel
            next.y = current.y
            controller.rootEntity.setPosition(next, relativeTo: nil)
        }
        controller.steerScriptedRootTowardWorldDirection(
            direction,
            deltaTime: Float(deltaTime),
            maximumYawRateDegreesPerSecond:
                configuration.maximumYawRateDegreesPerSecond
        )
    }

    func cancel(reason: String) {
        controller?.stopScriptedLocomotion(reason: reason)
        completion = nil
        controller = nil
        spatialProvider = nil
        pendingAuthoredTravel = 0
        isActive = false
    }

    private func finish() {
        isActive = false
        let callback = completion
        completion = nil
        callback?()
    }

    static func desiredTarget(
        headPosition: SIMD3<Float>,
        headForward: SIMD3<Float>,
        floorY: Float,
        stopDistanceMeters: Float
    ) -> SIMD3<Float> {
        let horizontalForward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(headForward.x, 0, headForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )
        var target = headPosition + horizontalForward * stopDistanceMeters
        target.y = floorY
        return target
    }

    static func clampToMappedFloor(
        _ point: SIMD3<Float>,
        floors: [FloorCandidate],
        edgeInsetMeters: Float = 0.12
    ) -> SIMD3<Float> {
        let candidates = floors.filter(\.isUsableFloor).map { floor -> SIMD3<Float> in
            let right = PhaseOneMath.normalizedOrFallback(
                floor.right,
                fallback: SIMD3<Float>(1, 0, 0)
            )
            let forward = PhaseOneMath.normalizedOrFallback(
                floor.forward,
                fallback: SIMD3<Float>(0, 0, -1)
            )
            let delta = point - floor.center
            let halfWidth = max(0, floor.width * 0.5 - edgeInsetMeters)
            let halfDepth = max(0, floor.depth * 0.5 - edgeInsetMeters)
            let localRight = min(halfWidth, max(-halfWidth, simd_dot(delta, right)))
            let localForward = min(halfDepth, max(-halfDepth, simd_dot(delta, forward)))
            var clamped = floor.center + right * localRight + forward * localForward
            clamped.y = point.y
            return clamped
        }
        return candidates.min {
            simd_distance_squared($0, point) < simd_distance_squared($1, point)
        } ?? point
    }
}
