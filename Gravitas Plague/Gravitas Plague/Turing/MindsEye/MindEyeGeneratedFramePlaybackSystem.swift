import Foundation
import RealityKit

@MainActor
final class MindEyeGeneratedFramePlaybackSystem: System {
    private static let query = EntityQuery(where: .has(MindEyeGeneratedFramePlaybackComponent.self))

    required init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        #if GR_MIND_EYE_QUALIFICATION
        let qualificationStart = ContinuousClock.now
        defer {
            MindEyeReleaseQualificationHooks.shared.recordSystemCPU(
                .generated,
                startedAt: qualificationStart
            )
        }
        #endif
        let now = ContinuousClock.now
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let component = entity.components[MindEyeGeneratedFramePlaybackComponent.self],
                  !component.isPaused else { continue }
            switch MindEyeGeneratedFramePlaybackRegistry.shared.advance(
                token: component.registrationToken, now: now
            ) {
            case .unchanged, .delivered: break
            case .missing, .failed:
                entity.components.remove(MindEyeGeneratedFramePlaybackComponent.self)
            }
        }
    }
}
