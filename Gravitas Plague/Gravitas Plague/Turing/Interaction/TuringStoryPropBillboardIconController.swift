import Foundation
import RealityKit

struct TuringStoryWalkieMicBillboardComponent: Component {
}

extension Notification.Name {
    static let turingStoryWalkieMicHoldBegan =
        Notification.Name("turingStoryWalkieMicHoldBegan")

    static let turingStoryWalkieMicHoldEnded =
        Notification.Name("turingStoryWalkieMicHoldEnded")
}

@MainActor
final class TuringStoryPropBillboardIconController {
    private var micIconEntity: Entity?

    func installWalkieMicIcon(
        anchor: Entity,
        target: TuringScriptTriggerTarget,
        onHoldBegan: @escaping @MainActor () -> Void,
        onHoldEnded: @escaping @MainActor () -> Void
    ) {
        removeWalkieMicIcon()

        let icon = Entity()
        icon.name = "TuringStoryWalkieTalkie_MicHitTarget"
        icon.position = SIMD3<Float>(0, 0, 0)
        icon.components.set(TuringStoryWalkieMicBillboardComponent())
        icon.components.set(InputTargetComponent())
        icon.components.set(
            CollisionComponent(
                shapes: [
                    .generateBox(
                        size: SIMD3<Float>(0.11, 0.11, 0.012)
                    )
                ]
            )
        )
        anchor.addChild(icon)
        micIconEntity = icon

        print("""
        [TuringWalkieBundle] mic billboard installed
          anchor: \(anchor.name)
          target: \(target.rawValue)
        """)
    }

    func removeWalkieMicIcon() {
        micIconEntity?.removeFromParent()
        micIconEntity = nil
    }
}
