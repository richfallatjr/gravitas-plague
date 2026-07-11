import Foundation
import RealityKit
import simd

enum TuringStoryRuntimePlacement: Sendable {
    case door(TuringStoryDoorBundlePlacement)
    case window(TuringStoryWindowBundlePlacement)
    case walkieShelf(TuringStoryWallBundlePlacement)
    case poster(WallPosterPlacement)

    var wallID: UUID {
        switch self {
        case .door(let value): return value.wallID
        case .window(let value): return value.wallID
        case .walkieShelf(let value): return value.wallID
        case .poster(let value): return value.wallID
        }
    }

    var localX: Float {
        switch self {
        case .door(let value): return value.localX
        case .window(let value): return value.localX
        case .walkieShelf(let value): return value.localX
        case .poster(let value): return value.localX
        }
    }

    var localY: Float {
        switch self {
        case .door(let value): return value.localY
        case .window(let value): return value.localY
        case .walkieShelf(let value): return value.localY
        case .poster(let value): return value.localY
        }
    }

    var depthOffset: Float {
        switch self {
        case .door(let value): return value.depthOffset
        case .window(let value): return value.depthOffset
        case .walkieShelf(let value): return value.depthOffset
        case .poster(let value): return value.depthOffset
        }
    }

    var visualWidth: Float {
        switch self {
        case .door(let value): return value.width
        case .window(let value): return value.width
        case .walkieShelf(let value): return value.width
        case .poster(let value): return value.width
        }
    }

    var visualHeight: Float {
        switch self {
        case .door(let value): return value.height
        case .window(let value): return value.height
        case .walkieShelf(let value): return value.height
        case .poster(let value): return value.height
        }
    }

    var floorWorldY: Float? {
        switch self {
        case .door(let value): return value.floorWorldY
        case .window(let value): return value.floorWorldY
        case .walkieShelf(let value): return value.floorWorldY
        case .poster: return nil
        }
    }
}

struct TuringStoryRuntimeSlot: Sendable {
    let slotID: String
    let propID: TuringStoryPropID
    let wallID: UUID
    let wallOrdinal: Int
    let sliceIDs: [String]
    let routeOrder: Float
    let worldTransform: simd_float4x4
    let semanticReservation: WallLocalRect
    let score: Float
    let placement: TuringStoryRuntimePlacement
}

struct TuringStoryPlacementAdjustmentSeed: Sendable {
    let scanID: String
    let candidatesByProp: [TuringStoryPropID: [TuringStoryRuntimeSlot]]
    let initiallySelectedSlotIDByProp: [TuringStoryPropID: String]
}

enum TuringStoryPlacementAdjustmentError: LocalizedError {
    case scanMismatch(expected: String, actual: String)
    case missingWall(UUID)
    case missingWallManager
    case missingOccupancyRegistry
    case missingController(TuringStoryPropID)
    case noCoveredSlice(slotID: String)
    case missingInitialSlot(propID: TuringStoryPropID, slotID: String)
    case wrongPlacementType(expected: TuringStoryPropID, slotID: String)
    case placementTransformUnavailable(slotID: String)
    case posterBaseSizeUnavailable
    case occupancyRegistrationFailed(TuringStoryPropID)

    var errorDescription: String? {
        switch self {
        case .scanMismatch(let expected, let actual):
            return "Adjustment seed scan mismatch. Expected \(expected), got \(actual)."
        case .missingWall(let id):
            return "Adjustment placement references missing live wall \(id)."
        case .missingWallManager:
            return "Adjustment controller has no wall manager."
        case .missingOccupancyRegistry:
            return "Adjustment controller has no occupancy registry."
        case .missingController(let propID):
            return "Adjustment controller is missing adapter for \(propID.rawValue)."
        case .noCoveredSlice(let slotID):
            return "Adjustment slot \(slotID) does not intersect a spin-ordered wall slice."
        case .missingInitialSlot(let propID, let slotID):
            return
                "Initial \(propID.rawValue) slot \(slotID) was not retained in the candidate cache."
        case .wrongPlacementType(let expected, let slotID):
            return
                "Adjustment slot \(slotID) does not contain the typed placement for \(expected.rawValue)."
        case .placementTransformUnavailable(let slotID):
            return "Could not resolve the live world transform for adjustment slot \(slotID)."
        case .posterBaseSizeUnavailable:
            return
                "Poster adjustment cannot proceed before the poster mesh has a committed base size."
        case .occupancyRegistrationFailed(let propID):
            return "Could not register adjusted occupancy for \(propID.rawValue)."
        }
    }
}

@MainActor
protocol TuringStoryAdjustablePlacementController: AnyObject {
    var adjustmentPropID: TuringStoryPropID { get }
    var adjustmentRoot: Entity { get }
    var adjustmentOccupancyID: UUID { get }

    /// Returns the last slot adopted or committed by the adjustment system.
    func currentPlacementSlot() -> TuringStoryRuntimeSlot?

    /// Records the already-committed Foundation-selected slot without changing
    /// transforms, assets, or occupancy. Called once when a new seed activates.
    func adoptCommittedAdjustmentSlot(
        _ slot: TuringStoryRuntimeSlot
    ) throws

    /// Moves only the already-loaded prop root. This method must never mutate
    /// occupancy or rebuild any authored child hierarchy.
    func previewPlannedPlacement(
        _ slot: TuringStoryRuntimeSlot,
        duration: TimeInterval
    )

    /// Commits the typed placement and replaces this prop's occupancy record
    /// exactly once using its stable occupancy UUID.
    func commitAdjustedPlacement(
        _ slot: TuringStoryRuntimeSlot
    ) throws

    /// Restores the exact last committed transform and any controller-specific
    /// visual scale. Occupancy remains untouched.
    func cancelPlacementPreview()
}

