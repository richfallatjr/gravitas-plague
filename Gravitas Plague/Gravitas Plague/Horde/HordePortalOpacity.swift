import RealityKit

extension Entity {
    @MainActor
    func applyOpacityRecursively(
        _ opacity: Float
    ) {
        let clamped = max(
            0,
            min(
                1,
                opacity
            )
        )

        components.set(
            OpacityComponent(
                opacity: clamped
            )
        )

        for child in children {
            child.applyOpacityRecursively(clamped)
        }
    }
}
