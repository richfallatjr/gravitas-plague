import Foundation
import RealityKit

@MainActor
final class MindEyeMotionSystem: System {
    private static let query = EntityQuery(
        where: .has(MindEyeMotionComponent.self)
    )

    required init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        #if GR_MIND_EYE_QUALIFICATION
        let qualificationStart = ContinuousClock.now
        defer {
            MindEyeReleaseQualificationHooks.shared.recordSystemCPU(
                .motion,
                startedAt: qualificationStart
            )
            MindEyeReleaseQualificationHooks.shared.recordFrameInterval(
                context.deltaTime
            )
        }
        #endif
        for entity in context.entities(
            matching: Self.query,
            updatingSystemWhen: .rendering
        ) {
            guard var component = entity.components[MindEyeMotionComponent.self],
                  component.isActive,
                  !component.isPaused else {
                continue
            }

            switch MindEyeMotionModel.advance(
                state: &component.runtimeState,
                deltaTime: context.deltaTime,
                tuning: component.tuning
            ) {
            case .success(let sample):
                let delivered = MindEyeMotionFrameRegistry.shared.publish(
                    sample,
                    token: component.registrationToken
                )
                if !delivered { component.isActive = false }
            case .failure(let failure):
                component.isActive = false
                MindEyeMotionFrameRegistry.shared.publishFailure(
                    failure,
                    token: component.registrationToken
                )
            }

            entity.components[MindEyeMotionComponent.self] = component
        }
    }
}
