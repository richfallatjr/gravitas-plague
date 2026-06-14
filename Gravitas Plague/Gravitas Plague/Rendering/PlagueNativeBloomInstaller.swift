import Foundation
import RealityKit

@MainActor
enum PlagueNativeBloomInstaller {
    static let targetIntensity: Float = 1.0
    static let targetStrength: Float = targetIntensity

    static func installStrictBloom(
        on root: Entity
    ) {
        guard #available(visionOS 27.0, *) else {
            fatalError("[PlagueBloom] visionOS 27 BloomComponent unavailable. No fallback.")
        }

        installBloomVisionOS27(
            on: root,
            label: "strict_bloom"
        )
    }

    static func installOnEntity(
        _ entity: Entity,
        label: String
    ) {
        guard #available(visionOS 27.0, *) else {
            fatalError(
                """
                [PlagueBloom] BloomComponent requires visionOS 27. No fallback.
                  label: \(label)
                """
            )
        }

        installBloomVisionOS27(
            on: entity,
            label: label
        )
    }

    @available(visionOS 27.0, *)
    private static func installBloomVisionOS27(
        on root: Entity,
        label: String
    ) {
        root.components.set(
            BloomComponent(
                scope: .hierarchical
            )
        )

        var options = BloomOptionsComponent()
        options.strength = targetStrength
        options.threshold = 0.65
        options.blurRadius = 0.80
        root.components.set(options)

        print(
            """
            [PlagueBloom] native RealityKit BloomComponent installed
              label: \(label)
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

    static func verifyInstalled(
        on entity: Entity,
        label: String
    ) {
        guard #available(visionOS 27.0, *) else {
            return
        }

        if entity.components[BloomComponent.self] == nil {
            print(
                """
                [PlagueBloom] ERROR BloomComponent missing
                  label: \(label)
                  reinstalling: true
                """
            )

            installOnEntity(
                entity,
                label: "\(label)_reinstall"
            )
        }
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
