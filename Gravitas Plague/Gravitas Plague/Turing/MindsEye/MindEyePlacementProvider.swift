import Foundation
import RealityKit

@MainActor
protocol MindEyePlacementAvailabilitySink: AnyObject {
    func mindEyePlacementProviderDidBecomeAvailable(
        providerID: String,
        surfaces: Set<StoryInteractionSurfaceID>,
        revision: UInt64
    )

    func mindEyePlacementProviderDidInvalidate(
        providerID: String,
        surfaces: Set<StoryInteractionSurfaceID>,
        revision: UInt64,
        reason: String
    )
}

@MainActor
struct MindEyePlacementTarget {
    let providerID: String
    let revision: UInt64
    let parent: Entity
    let geometry: MindEyePlacementGeometry
}

@MainActor
protocol MindEyePlacementProviding: AnyObject {
    var mindEyePlacementProviderID: String { get }
    var mindEyeSupportedSurfaces: Set<StoryInteractionSurfaceID> { get }

    func mindEyePlacementTarget(
        for surface: StoryInteractionSurfaceID
    ) -> MindEyePlacementTarget?

    func setMindEyePlacementAvailabilitySink(
        _ sink: (any MindEyePlacementAvailabilitySink)?
    )
}

@MainActor
final class MindEyePlacementProviderRegistry {
    private var providers: [
        StoryInteractionSurfaceID: any MindEyePlacementProviding
    ] = [:]

    func bind(
        _ provider: any MindEyePlacementProviding,
        sink: any MindEyePlacementAvailabilitySink
    ) -> Result<Void, MindEyeFailure> {
        for surface in provider.mindEyeSupportedSurfaces {
            if let existing = providers[surface],
               existing.mindEyePlacementProviderID !=
                provider.mindEyePlacementProviderID {
                return .failure(
                    MindEyeFailure(
                        code: .placementProviderConflict,
                        characterID: nil,
                        vignetteID: nil,
                        resourcePath: nil,
                        message: "Duplicate Mind's Eye placement provider for \(surface.rawValue)."
                    )
                )
            }
        }

        for surface in provider.mindEyeSupportedSurfaces {
            providers[surface] = provider
        }
        provider.setMindEyePlacementAvailabilitySink(sink)
        return .success(())
    }

    func target(for surface: StoryInteractionSurfaceID) -> MindEyePlacementTarget? {
        providers[surface]?.mindEyePlacementTarget(for: surface)
    }

    func removeAll() {
        var seen = Set<String>()
        let unique = providers.values.filter {
            seen.insert($0.mindEyePlacementProviderID).inserted
        }
        providers.removeAll(keepingCapacity: false)
        for provider in unique {
            provider.setMindEyePlacementAvailabilitySink(nil)
        }
    }

    var providerCount: Int {
        Set(providers.values.map(\.mindEyePlacementProviderID)).count
    }
}

@MainActor
enum MindEyeRealityBoundsAdapter {
    static func bounds(
        of entity: Entity,
        relativeTo reference: Entity
    ) -> MindEyeLocalBounds? {
        let bounds = entity.visualBounds(
            recursive: true,
            relativeTo: reference,
            excludeInactive: false
        )
        let value = MindEyeLocalBounds(min: bounds.min, max: bounds.max)
        return value.isUsable ? value : nil
    }

    static func iconTopCenter(
        of iconAnchor: Entity,
        relativeTo reference: Entity,
        fallbackTopOffsetMeters: Float
    ) -> SIMD3<Float> {
        if let bounds = bounds(of: iconAnchor, relativeTo: reference) {
            return SIMD3<Float>(
                bounds.center.x,
                bounds.max.y,
                bounds.center.z
            )
        }
        var fallback = iconAnchor.position(relativeTo: reference)
        fallback.y += fallbackTopOffsetMeters
        return fallback
    }
}
