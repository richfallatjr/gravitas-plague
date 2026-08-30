import Foundation
import RealityKit

@MainActor
final class Chapter03AngelBlendShapeController {
    private let descriptor: Chapter03AngelBlendShapeDescriptor
    private let response: Chapter03AngelBlendShapeResponse
    private var bindings: [Chapter03AngelBlendShapeBinding]

    private(set) var currentWeight: Float = 0
    private(set) var targetWeight: Float = 0
    private(set) var currentPose: MindEyeMouthPose = .rest
    private(set) var projectionReadiness = Chapter03AngelProjectionReadiness.unavailable
    private(set) var assignmentCount: UInt64 = 0
    private(set) var projectionNotReadyFrameCount: UInt64 = 0
    private(set) var maximumRequestedWeight: Float = 0
    private(set) var maximumAchievedWeight: Float = 0

    init(
        descriptor: Chapter03AngelBlendShapeDescriptor,
        bindings: [Chapter03AngelBlendShapeBinding]
    ) throws {
        guard !bindings.isEmpty else {
            throw Chapter03AngelBlendShapeError.targetNotFound(
                descriptor.blendShapeName
            )
        }
        self.descriptor = descriptor
        response = descriptor.response.runtimeValue
        self.bindings = bindings
        try assignExact(descriptor.fallbackWeight)
        Chapter03AngelBlendShapeDiagnostics.loaded(
            descriptor: descriptor,
            bindings: bindings
        )
    }

    func setProjectionReadiness(_ readiness: Chapter03AngelProjectionReadiness) {
        guard projectionReadiness != readiness else { return }
        projectionReadiness = readiness
        targetWeight = readiness.isReady
            ? descriptor.poseWeights.weight(for: currentPose)
            : descriptor.fallbackWeight
        maximumRequestedWeight = max(maximumRequestedWeight, targetWeight)
        Chapter03AngelBlendShapeDiagnostics.readinessChanged(readiness)
    }

    func setPose(_ pose: MindEyeMouthPose) {
        guard currentPose != pose else { return }
        currentPose = pose
        targetWeight = projectionReadiness.isReady
            ? descriptor.poseWeights.weight(for: pose)
            : descriptor.fallbackWeight
        maximumRequestedWeight = max(maximumRequestedWeight, targetWeight)
        Chapter03AngelBlendShapeDiagnostics.poseChanged(pose, target: targetWeight)
    }

    func update(deltaTime: TimeInterval) {
        if !projectionReadiness.isReady, currentPose != .rest {
            projectionNotReadyFrameCount &+= 1
        }
        let next = response.step(
            current: currentWeight,
            target: targetWeight,
            deltaTime: Float(deltaTime)
        )
        guard abs(next - currentWeight) >= response.assignmentEpsilon ||
                next == targetWeight && currentWeight != targetWeight else {
            return
        }
        do {
            try assignExact(next)
            currentWeight = next
            maximumAchievedWeight = max(maximumAchievedWeight, next)
        } catch {
            projectionReadiness = .unavailable
            targetWeight = descriptor.fallbackWeight
            if (try? assignExact(descriptor.fallbackWeight)) != nil {
                currentWeight = descriptor.fallbackWeight
            }
            Chapter03AngelBlendShapeDiagnostics.assignmentFailed(error: error)
        }
    }

    func reset(immediately: Bool, reason: String) {
        currentPose = .rest
        targetWeight = descriptor.fallbackWeight
        projectionReadiness = .unavailable
        if immediately {
            try? assignExact(descriptor.fallbackWeight)
            currentWeight = descriptor.fallbackWeight
        }
        Chapter03AngelBlendShapeDiagnostics.reset(
            reason: reason,
            assignmentCount: assignmentCount
        )
    }

    private func assignExact(_ requested: Float) throws {
        let value = min(1, max(0, requested))
        for binding in bindings {
            guard let entity = binding.entity else {
                throw Chapter03AngelBlendShapeError.entityReleased(
                    binding.entityPath
                )
            }
            var groups = entity.blendWeights
            guard groups.indices.contains(binding.groupIndex),
                  groups[binding.groupIndex].indices.contains(binding.weightIndex) else {
                throw Chapter03AngelBlendShapeError.staleBinding
            }
            groups[binding.groupIndex][binding.weightIndex] = value
            entity.blendWeights = groups
        }
        assignmentCount &+= 1
    }
}
