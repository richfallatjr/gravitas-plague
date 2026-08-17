import RealityKit
import UIKit

nonisolated enum StoryDeviceActivityPresentation: Sendable, Equatable {
    case hidden
    case playing(surface: StoryInteractionSurfaceID)
}

@MainActor
final class TuringStoryDeviceActivityIconController {
    static let shared = TuringStoryDeviceActivityIconController()

    private var markers: [StoryInteractionSurfaceID: ModelEntity] = [:]
    private var presentation: StoryDeviceActivityPresentation = .hidden

    private init() {}

    func register(
        surface: StoryInteractionSurfaceID,
        parent: Entity,
        transform: Transform,
        size: Float
    ) {
        unregister(surface: surface)
        let material: UnlitMaterial
        if let styled = try? TuringStoryActionIconVisualStyle.material(
            symbolName: "play.fill"
        ) {
            material = styled
        } else {
            var fallback = UnlitMaterial()
            fallback.color = .init(tint: .orange)
            fallback.blending = .transparent(opacity: .init(floatLiteral: 0.92))
            material = fallback
        }
        let marker = ModelEntity(
            mesh: .generatePlane(width: size, height: size),
            materials: [material]
        )
        marker.name = "TuringStoryPlayMode_Active_\(surface.rawValue)"
        marker.transform = transform
        marker.components.remove(InputTargetComponent.self)
        marker.components.remove(CollisionComponent.self)
        marker.isEnabled = false
        parent.addChild(marker)
        markers[surface] = marker
        applyPresentation()
    }

    func unregister(surface: StoryInteractionSurfaceID) {
        markers.removeValue(forKey: surface)?.removeFromParent()
    }

    func setPresentation(_ presentation: StoryDeviceActivityPresentation) {
        self.presentation = presentation
        applyPresentation()
    }

    func removeAll() {
        for marker in markers.values {
            marker.removeFromParent()
        }
        markers.removeAll(keepingCapacity: false)
        presentation = .hidden
    }

    private func applyPresentation() {
        for (surface, marker) in markers {
            marker.isEnabled = presentation == .playing(surface: surface)
        }
    }
}
