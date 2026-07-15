import RealityKit
import XCTest
import simd

@testable import Gravitas_Plague

@MainActor
final class TuringStoryPlacementMockAdapter:
    TuringStoryAdjustablePlacementController
{

    let adjustmentPropID: TuringStoryPropID
    let adjustmentRoot = Entity()
    let adjustmentOccupancyID = UUID()

    private let occupancyRegistry: WallPropOccupancyRegistry?
    private(set) var committedSlot: TuringStoryRuntimeSlot?
    private(set) var previewedSlots: [TuringStoryRuntimeSlot] = []
    private(set) var commitCount = 0
    private(set) var cancelCount = 0
    private var committedTransform = matrix_identity_float4x4

    init(
        propID: TuringStoryPropID,
        occupancyRegistry: WallPropOccupancyRegistry? = nil
    ) {
        adjustmentPropID = propID
        self.occupancyRegistry = occupancyRegistry
    }

    func currentPlacementSlot() -> TuringStoryRuntimeSlot? {
        committedSlot
    }

    func adoptCommittedAdjustmentSlot(
        _ slot: TuringStoryRuntimeSlot
    ) throws {
        guard slot.propID == adjustmentPropID else {
            throw TuringStoryPlacementAdjustmentError.wrongPlacementType(
                expected: adjustmentPropID,
                slotID: slot.slotID
            )
        }
        committedSlot = slot
        committedTransform = slot.worldTransform
        adjustmentRoot.setTransformMatrix(slot.worldTransform, relativeTo: nil)
    }

    func previewPlannedPlacement(
        _ slot: TuringStoryRuntimeSlot,
        duration: TimeInterval
    ) {
        _ = duration
        previewedSlots.append(slot)
        adjustmentRoot.setTransformMatrix(slot.worldTransform, relativeTo: nil)
    }

    func commitAdjustedPlacement(
        _ slot: TuringStoryRuntimeSlot
    ) throws {
        guard slot.propID == adjustmentPropID else {
            throw TuringStoryPlacementAdjustmentError.wrongPlacementType(
                expected: adjustmentPropID,
                slotID: slot.slotID
            )
        }
        commitCount += 1
        adjustmentRoot.setTransformMatrix(slot.worldTransform, relativeTo: nil)
        committedSlot = slot
        committedTransform = slot.worldTransform
        occupancyRegistry?.unregister(id: adjustmentOccupancyID)
        occupancyRegistry?.register(
            id: adjustmentOccupancyID,
            wallID: slot.wallID,
            kind: adjustmentPropID.occupancyKind,
            rect: slot.semanticReservation,
            padding: 0,
            label: "test \(adjustmentPropID.rawValue)"
        )
    }

    func cancelPlacementPreview() {
        cancelCount += 1
        adjustmentRoot.setTransformMatrix(committedTransform, relativeTo: nil)
    }
}

@MainActor
final class TuringStoryPlacementMockBars:
    TuringStoryPlacementAdjustmentBarPresenting
{

    var activeSlots: [TuringStoryPropID: TuringStoryRuntimeSlot] = [:]
    var previews: [TuringStoryRuntimeSlot] = []
    var commits: [TuringStoryRuntimeSlot] = []
    var states: [TuringStoryPropID: TuringStoryPlacementAdjustmentBarVisualState] = [:]
    var enabled: [TuringStoryPropID: Bool] = [:]
    var hideReasons: [String] = []
    var worldAxis = SIMD3<Float>(1, 0, 0)

    func install(sceneRoot: Entity) {
        _ = sceneRoot
    }

    func show(activeSlots: [TuringStoryPropID: TuringStoryRuntimeSlot]) {
        self.activeSlots = activeSlots
    }

    func preview(slot: TuringStoryRuntimeSlot, duration: TimeInterval) {
        _ = duration
        previews.append(slot)
    }

    func commit(slot: TuringStoryRuntimeSlot) {
        commits.append(slot)
        activeSlots[slot.propID] = slot
    }

    func worldRightAxis(for propID: TuringStoryPropID) -> SIMD3<Float> {
        _ = propID
        return worldAxis
    }

    func setVisualState(
        _ state: TuringStoryPlacementAdjustmentBarVisualState,
        propID: TuringStoryPropID
    ) {
        states[propID] = state
    }

    func setEnabled(_ enabled: Bool, propID: TuringStoryPropID) {
        self.enabled[propID] = enabled
    }

    func hideAll(reason: String) {
        activeSlots.removeAll()
        hideReasons.append(reason)
    }
}

@MainActor
final class TuringStoryPlacementFakeWallProvider:
    TuringStoryAdjustmentWallProviding
{

    var walls: [UUID: TuringStoryAdjustmentWallBasis] = [:]

    func turingStoryAdjustmentWallBasis(
        for wallID: UUID
    ) -> TuringStoryAdjustmentWallBasis? {
        walls[wallID]
    }
}

enum TuringStoryPlacementTestFactory {
    static func slot(
        id: String,
        propID: TuringStoryPropID,
        wallID: UUID,
        wallOrdinal: Int,
        routeOrder: Float,
        localX: Float = 0,
        localY: Float = 1,
        width: Float = 0.6,
        height: Float = 0.5,
        floorWorldY: Float = 0,
        rect: WallLocalRect? = nil
    ) -> TuringStoryRuntimeSlot {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(localX, localY, 0.02, 1)
        let reservation =
            rect
            ?? WallLocalRect(
                minX: localX - width * 0.5,
                minY: localY - height * 0.5,
                maxX: localX + width * 0.5,
                maxY: localY + height * 0.5
            )

        let placement: TuringStoryRuntimePlacement
        switch propID {
        case .door:
            placement = .door(
                TuringStoryDoorBundlePlacement(
                    wallID: wallID,
                    localX: localX,
                    localY: localY,
                    depthOffset: 0.018,
                    width: width,
                    height: height,
                    floorWorldY: floorWorldY,
                    worldYawRadians: 0
                )
            )
        case .rollingBench:
            placement = .rollingBench(
                TuringRollingBenchBundlePlacement(
                    wallID: wallID,
                    localX: localX,
                    localY: localY,
                    depthOffset: 0.018,
                    width: width,
                    height: height,
                    floorWorldY: floorWorldY
                )
            )
        case .window:
            placement = .window(
                TuringStoryWindowBundlePlacement(
                    wallID: wallID,
                    localX: localX,
                    localY: localY,
                    depthOffset: 0.018,
                    width: width,
                    height: height,
                    floorWorldY: floorWorldY,
                    worldYawRadians: 0
                )
            )
        case .walkieShelf:
            placement = .walkieShelf(
                TuringStoryWallBundlePlacement(
                    wallID: wallID,
                    localX: localX,
                    localY: localY,
                    depthOffset: 0.025,
                    width: width,
                    height: height,
                    floorWorldY: floorWorldY
                )
            )
        case .poster:
            placement = .poster(
                WallPosterPlacement(
                    wallID: wallID,
                    localX: localX,
                    localY: localY,
                    depthOffset: 0.018,
                    width: width,
                    height: height
                )
            )
        }

        return TuringStoryRuntimeSlot(
            slotID: id,
            propID: propID,
            wallID: wallID,
            wallOrdinal: wallOrdinal,
            sliceIDs: ["\(wallOrdinal)0"],
            routeOrder: routeOrder,
            worldTransform: transform,
            semanticReservation: reservation,
            score: 1,
            placement: placement
        )
    }

    static func seed(
        scanID: String = "TEST",
        routes: [TuringStoryPropID: [TuringStoryRuntimeSlot]],
        active: [TuringStoryPropID: TuringStoryRuntimeSlot]
    ) -> TuringStoryPlacementAdjustmentSeed {
        TuringStoryPlacementAdjustmentSeed(
            scanID: scanID,
            candidatesByProp: routes,
            initiallySelectedSlotIDByProp: active.mapValues(\.slotID)
        )
    }
}
