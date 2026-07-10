import Foundation

enum TuringStoryPropID: String, Codable, CaseIterable, Sendable, Hashable {
    case door
    case window
    case walkieShelf
    case poster

    var shortID: String {
        switch self {
        case .door: return "d"
        case .window: return "w"
        case .walkieShelf: return "s"
        case .poster: return "p"
        }
    }

    var priority: Int {
        switch self {
        case .door: return 1
        case .window: return 2
        case .walkieShelf: return 3
        case .poster: return 4
        }
    }

    var occupancyKind: WallPropOccupancyKind {
        switch self {
        case .door: return .storyDoorBundle
        case .window: return .storyWindowBundle
        case .walkieShelf: return .storyWalkieBundle
        case .poster: return .wallPoster
        }
    }
}

struct TuringStoryPlanningEnvelope: Sendable, Hashable {
    let propID: TuringStoryPropID
    let minimumWidthMeters: Float
    let preferredWidthMeters: Float
    let maximumWidthMeters: Float
    let bottomAboveFloorMeters: Float
    let topAboveFloorMeters: Float
    let preferredFrontageDepthMeters: Float
    let wallMarginMeters: Float
    let depthOffsetMeters: Float

    var reservationHeightMeters: Float {
        topAboveFloorMeters - bottomAboveFloorMeters
    }

    static func all(posterSize: SIMD2<Float>) -> [TuringStoryPlanningEnvelope] {
        [
            .init(
                propID: .door,
                minimumWidthMeters: 1.2192,
                preferredWidthMeters: 1.3716,
                maximumWidthMeters: 1.5240,
                bottomAboveFloorMeters: 0,
                topAboveFloorMeters: 2.2860,
                preferredFrontageDepthMeters: 0.90,
                wallMarginMeters: TuringStoryDoorBundleTuning.wallMarginMeters,
                depthOffsetMeters: TuringStoryDoorBundleTuning.depthOffset
            ),
            .init(
                propID: .window,
                minimumWidthMeters: 0.9144,
                preferredWidthMeters: 1.0668,
                maximumWidthMeters: 1.2192,
                bottomAboveFloorMeters: 0.85344,
                topAboveFloorMeters: 1.8288,
                preferredFrontageDepthMeters: 0.45,
                wallMarginMeters: TuringStoryWindowBundleTuning.wallMarginMeters,
                depthOffsetMeters: TuringStoryWindowBundleTuning.depthOffset
            ),
            .init(
                propID: .walkieShelf,
                minimumWidthMeters: 0.9144,
                preferredWidthMeters: 0.9144,
                maximumWidthMeters: 0.9144,
                bottomAboveFloorMeters: 1.2192,
                topAboveFloorMeters: 1.6764,
                preferredFrontageDepthMeters: 0.45,
                wallMarginMeters: TuringStoryWalkieBundleTuning.wallMarginMeters,
                depthOffsetMeters: TuringStoryWalkieBundleTuning.depthOffset
            ),
            .init(
                propID: .poster,
                minimumWidthMeters: posterSize.x,
                preferredWidthMeters: posterSize.x,
                maximumWidthMeters: posterSize.x,
                bottomAboveFloorMeters: max(
                    WallPosterPlacementTuning.minBottomClearanceMeters,
                    WallPosterPlacementTuning.preferredCenterHeightMeters - posterSize.y * 0.5
                ),
                topAboveFloorMeters: max(
                    WallPosterPlacementTuning.preferredCenterHeightMeters,
                    WallPosterPlacementTuning.minBottomClearanceMeters + posterSize.y * 0.5
                ) + posterSize.y * 0.5,
                preferredFrontageDepthMeters: 0,
                wallMarginMeters: WallPosterPlacementTuning.wallMarginMeters,
                depthOffsetMeters: WallPosterMetrics.depthOffset
            )
        ]
    }

    // Rendering-only helpers never become planning occupancy: occlusion cards,
    // portalPlane geometry, window glass, and other renderingOnly masks.
    static let renderingOnlyEntityTokens = [
        "occlusion", "portalPlane", "glass", "depthOnly", "renderingOnly"
    ]
}

struct TuringStorySemanticRect: Codable, Sendable, Hashable {
    let minX: Float
    let minY: Float
    let maxX: Float
    let maxY: Float

    var wallLocalRect: WallLocalRect {
        WallLocalRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    func overlaps(_ other: TuringStorySemanticRect) -> Bool {
        minX < other.maxX && maxX > other.minX &&
            minY < other.maxY && maxY > other.minY
    }
}

enum TuringStoryHotspotLayoutError: LocalizedError {
    case noUsableFloor
    case noCanonicalWalls
    case noPerimeter
    case noLegalDoorPlacement
    case noHotspotAtlas
    case compactHotspotPromptStillTooLarge
    case malformedResponse(String)
    case scanMismatch
    case unknownHotspot(String)
    case hotspotPropMismatch(String)
    case invalidNormalizedPosition(String)
    case placementResolutionFailed(String)
    case placementVectorMismatch
    case selectedOverlap(String, String)
    case fixedOccupancyOverlap(String)
    case liveWallMissing(String)
    case liveWallDrift(String)
    case assetPreparationFailed(String)
    case commitFailed(String)
    case secondPlanInvalid(String)

    var errorDescription: String? {
        switch self {
        case .noUsableFloor: return "No usable floor was available for Story placement."
        case .noCanonicalWalls: return "No canonical walls survived scan cleansing."
        case .noPerimeter: return "No room perimeter could be built."
        case .noLegalDoorPlacement: return "No exact legal door placement exists."
        case .noHotspotAtlas: return "No legal hotspot atlas could be built."
        case .compactHotspotPromptStillTooLarge: return "compactHotspotPromptStillTooLarge"
        case .malformedResponse(let detail): return "Malformed hotspot response: \(detail)"
        case .scanMismatch: return "Foundation hotspot response scan ID did not match."
        case .unknownHotspot(let value): return "Unknown hotspot: \(value)"
        case .hotspotPropMismatch(let value): return "Hotspot belongs to the wrong prop: \(value)"
        case .invalidNormalizedPosition(let value): return "Invalid hotspot position: \(value)"
        case .placementResolutionFailed(let value): return "Could not resolve hotspot selection: \(value)"
        case .placementVectorMismatch: return "Foundation response violated the required priority vector."
        case .selectedOverlap(let lhs, let rhs): return "Semantic reservations overlap: \(lhs), \(rhs)"
        case .fixedOccupancyOverlap(let value): return "Placement overlaps fixed occupancy: \(value)"
        case .liveWallMissing(let value): return "Live wall is missing: \(value)"
        case .liveWallDrift(let value): return "Live wall drift exceeded tolerance: \(value)"
        case .assetPreparationFailed(let value): return "Asset preparation failed: \(value)"
        case .commitFailed(let value): return "Atomic commit failed: \(value)"
        case .secondPlanInvalid(let value): return "Spatial replan remained invalid: \(value)"
        }
    }
}
