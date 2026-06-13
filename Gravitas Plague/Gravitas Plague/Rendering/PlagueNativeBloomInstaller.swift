import Foundation
import RealityKit

@MainActor
enum PlagueNativeBloomInstaller {
    static let targetIntensity: Float = 0.80

    static func installStrictBloom(
        on root: Entity
    ) {
        guard #available(visionOS 27.0, *) else {
            fatalError("[PlagueBloom] visionOS 27 BloomComponent unavailable. No fallback.")
        }

        installBloomVisionOS27(
            on: root
        )
    }

    @available(visionOS 27.0, *)
    private static func installBloomVisionOS27(
        on root: Entity
    ) {
        root.components.set(
            BloomComponent(
                scope: .hierarchical
            )
        )

        var options = BloomOptionsComponent()
        options.strength = targetIntensity
        options.threshold = 0.65
        options.blurRadius = 0.80
        root.components.set(options)

        print(
            """
            [PlagueBloom] native RealityKit BloomComponent installed
              intensityTarget: \(targetIntensity)
              threshold: \(options.threshold)
              blurRadius: \(options.blurRadius)
              scope: hierarchical
              api: BloomComponent
              strict: true
              noFallback: true
            """
        )
    }

    static func removeBloom(
        from root: Entity
    ) {
        if #available(visionOS 27.0, *) {
            root.components.remove(BloomComponent.self)
            root.components.remove(BloomOptionsComponent.self)

            print("[PlagueBloom] native BloomComponent removed")
        }
    }
}
