import RealityKit
import XCTest
import simd

@testable import Gravitas_Plague

@MainActor
final class TuringStoryPlacementAdjustmentCoordinatorTests: XCTestCase {
    func testOnlyOnePropCanBeActiveAtATime() throws {
        let registry = WallPropOccupancyRegistry()
        let bars = TuringStoryPlacementMockBars()
        let door = TuringStoryPlacementMockAdapter(
            propID: .door,
            occupancyRegistry: registry
        )
        let window = TuringStoryPlacementMockAdapter(
            propID: .window,
            occupancyRegistry: registry
        )
        let wallA = UUID()
        let wallB = UUID()
        let doorA = slot("d:a", .door, wallA, 1, 1.1, -0.5)
        let doorB = slot("d:b", .door, wallA, 1, 1.2, 0.5)
        let windowA = slot("w:a", .window, wallB, 2, 2.1, -0.5)
        let windowB = slot("w:b", .window, wallB, 2, 2.2, 0.5)
        let coordinator = makeCoordinator(
            registry: registry,
            bars: bars,
            adapters: [.door: door, .window: window]
        )
        activate(
            coordinator,
            registry: registry,
            routes: [.door: [doorA, doorB], .window: [windowA, windowB]],
            active: [.door: doorA, .window: windowA],
            adapters: [.door: door, .window: window]
        )

        coordinator.begin(propID: .door, worldPoint: .zero)
        coordinator.begin(propID: .window, worldPoint: .zero)

        XCTAssertEqual(coordinator.activePropIDForTesting, .door)
        XCTAssertEqual(bars.enabled[.window], false)
        coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))
        XCTAssertEqual(door.previewedSlots.last?.slotID, doorB.slotID)
        XCTAssertTrue(window.previewedSlots.isEmpty)
    }

    func testPositiveSixPointFiveCentimeterDragAdvancesOneCandidate() {
        let setup = makeSinglePropSetup(activeIndex: 0)

        setup.coordinator.begin(propID: .window, worldPoint: .zero)
        setup.coordinator.update(worldPoint: SIMD3<Float>(0.0651, 0, 0))

        XCTAssertEqual(setup.adapter.previewedSlots.map(\.slotID), ["w:1"])
    }

    func testNegativeSixPointFiveCentimeterDragMovesBackward() {
        let setup = makeSinglePropSetup(activeIndex: 1)

        setup.coordinator.begin(propID: .window, worldPoint: .zero)
        setup.coordinator.update(worldPoint: SIMD3<Float>(-0.0651, 0, 0))

        XCTAssertEqual(setup.adapter.previewedSlots.map(\.slotID), ["w:0"])
    }

    func testHysteresisPreventsJitterToggle() {
        let setup = makeSinglePropSetup(activeIndex: 0)

        setup.coordinator.begin(propID: .window, worldPoint: .zero)
        setup.coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))
        setup.coordinator.update(worldPoint: SIMD3<Float>(0.046, 0, 0))

        XCTAssertEqual(setup.adapter.previewedSlots.map(\.slotID), ["w:1"])
    }

    func testRouteWrapsAcrossFinalSlot() {
        let setup = makeSinglePropSetup(activeIndex: 2)

        setup.coordinator.begin(propID: .window, worldPoint: .zero)
        setup.coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))

        XCTAssertEqual(setup.adapter.previewedSlots.last?.slotID, "w:0")
    }

    func testWallBoundaryTraversalMatchesVisualLeftAndRight() {
        let registry = WallPropOccupancyRegistry()
        let bars = TuringStoryPlacementMockBars()
        let adapter = TuringStoryPlacementMockAdapter(
            propID: .window,
            occupancyRegistry: registry
        )
        let currentWall = UUID()
        let nextWall = UUID()
        let currentLeft = slot(
            "w:current:left",
            .window,
            currentWall,
            2,
            2.1,
            -0.8
        )
        let currentRight = slot(
            "w:current:right",
            .window,
            currentWall,
            2,
            2.2,
            0.8
        )
        let nextLeft = slot(
            "w:next:left",
            .window,
            nextWall,
            1,
            1.1,
            -0.8
        )
        let nextRight = slot(
            "w:next:right",
            .window,
            nextWall,
            1,
            1.2,
            0.8
        )
        let coordinator = makeCoordinator(
            registry: registry,
            bars: bars,
            adapters: [.window: adapter]
        )
        activate(
            coordinator,
            registry: registry,
            routes: [
                .window: [
                    currentLeft,
                    currentRight,
                    nextLeft,
                    nextRight,
                ]
            ],
            active: [.window: currentRight],
            adapters: [.window: adapter]
        )

        coordinator.begin(propID: .window, worldPoint: .zero)
        coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))
        XCTAssertEqual(
            adapter.previewedSlots.last?.slotID,
            nextLeft.slotID
        )

        coordinator.update(worldPoint: SIMD3<Float>(0.0, 0, 0))
        XCTAssertEqual(
            adapter.previewedSlots.last?.slotID,
            currentRight.slotID
        )
    }

    func testPreviewDoesNotMutateOccupancy() {
        let setup = makeSinglePropSetup(activeIndex: 0)
        let before = setup.registry.recordsByID[
            setup.adapter.adjustmentOccupancyID
        ]

        setup.coordinator.begin(propID: .window, worldPoint: .zero)
        setup.coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))

        let after = setup.registry.recordsByID[
            setup.adapter.adjustmentOccupancyID
        ]
        XCTAssertEqual(before?.wallID, after?.wallID)
        XCTAssertEqual(before?.rect, after?.rect)
        XCTAssertEqual(before?.padding, after?.padding)
    }

    func testReleaseUpdatesOnlyActivePropOccupancy() throws {
        let registry = WallPropOccupancyRegistry()
        let bars = TuringStoryPlacementMockBars()
        let door = TuringStoryPlacementMockAdapter(
            propID: .door,
            occupancyRegistry: registry
        )
        let window = TuringStoryPlacementMockAdapter(
            propID: .window,
            occupancyRegistry: registry
        )
        let doorWall = UUID()
        let windowWall = UUID()
        let doorSlot = slot("d:0", .door, doorWall, 1, 1.1, 0)
        let windowA = slot("w:0", .window, windowWall, 2, 2.1, -0.8)
        let windowB = slot("w:1", .window, windowWall, 2, 2.2, 0.8)
        let coordinator = makeCoordinator(
            registry: registry,
            bars: bars,
            adapters: [.door: door, .window: window]
        )
        activate(
            coordinator,
            registry: registry,
            routes: [.door: [doorSlot], .window: [windowA, windowB]],
            active: [.door: doorSlot, .window: windowA],
            adapters: [.door: door, .window: window]
        )
        let doorBefore = registry.recordsByID[door.adjustmentOccupancyID]

        coordinator.begin(propID: .window, worldPoint: .zero)
        coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))
        coordinator.end(commit: true)

        XCTAssertEqual(window.commitCount, 1)
        XCTAssertEqual(door.commitCount, 0)
        XCTAssertEqual(
            registry.recordsByID[window.adjustmentOccupancyID]?.rect,
            windowB.semanticReservation
        )
        XCTAssertEqual(
            registry.recordsByID[door.adjustmentOccupancyID]?.rect,
            doorBefore?.rect
        )
    }

    func testCancelRestoresOriginalTransformAndOccupancy() {
        let setup = makeSinglePropSetup(activeIndex: 0)
        let original = setup.routes[0]
        let occupancyBefore = setup.registry.recordsByID[
            setup.adapter.adjustmentOccupancyID
        ]

        setup.coordinator.begin(propID: .window, worldPoint: .zero)
        setup.coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))
        setup.coordinator.end(commit: false)

        XCTAssertEqual(setup.adapter.cancelCount, 1)
        XCTAssertEqual(setup.adapter.commitCount, 0)
        XCTAssertEqual(
            setup.coordinator.activeSlotForTesting(propID: .window)?.slotID,
            original.slotID
        )
        XCTAssertEqual(
            setup.registry.recordsByID[setup.adapter.adjustmentOccupancyID]?.rect,
            occupancyBefore?.rect
        )
        assertMatrix(
            setup.adapter.adjustmentRoot.transformMatrix(relativeTo: nil),
            equals: original.worldTransform
        )
    }

    func testOtherPropOccupancyFiltersAlternativeBeforePreview() throws {
        let registry = WallPropOccupancyRegistry()
        let bars = TuringStoryPlacementMockBars()
        let window = TuringStoryPlacementMockAdapter(
            propID: .window,
            occupancyRegistry: registry
        )
        let door = TuringStoryPlacementMockAdapter(
            propID: .door,
            occupancyRegistry: registry
        )
        let wall = UUID()
        let current = slot("w:0", .window, wall, 1, 1.1, -1.0)
        let blocked = slot("w:1", .window, wall, 1, 1.2, 0.0)
        let legal = slot("w:2", .window, wall, 1, 1.3, 1.0)
        let doorSlot = TuringStoryPlacementTestFactory.slot(
            id: "d:0",
            propID: .door,
            wallID: wall,
            wallOrdinal: 1,
            routeOrder: 1.25,
            localX: 0,
            localY: 1,
            width: 0.6,
            height: 0.6,
            rect: blocked.semanticReservation
        )
        let coordinator = makeCoordinator(
            registry: registry,
            bars: bars,
            adapters: [.window: window, .door: door]
        )
        activate(
            coordinator,
            registry: registry,
            routes: [.window: [current, blocked, legal], .door: [doorSlot]],
            active: [.window: current, .door: doorSlot],
            adapters: [.window: window, .door: door]
        )

        coordinator.begin(propID: .window, worldPoint: .zero)
        coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))

        XCTAssertEqual(window.previewedSlots.last?.slotID, legal.slotID)
        XCTAssertFalse(
            window.previewedSlots.contains(where: {
                $0.slotID == blocked.slotID
            }))
    }

    func testLowerPriorityPropCanMoveAfterHigherPriorityCommit() throws {
        let registry = WallPropOccupancyRegistry()
        let bars = TuringStoryPlacementMockBars()
        let door = TuringStoryPlacementMockAdapter(
            propID: .door,
            occupancyRegistry: registry
        )
        let poster = TuringStoryPlacementMockAdapter(
            propID: .poster,
            occupancyRegistry: registry
        )
        let doorWall = UUID()
        let posterWall = UUID()
        let doorA = slot("d:0", .door, doorWall, 1, 1.1, -0.8)
        let doorB = slot("d:1", .door, doorWall, 1, 1.2, 0.8)
        let posterA = slot("p:0", .poster, posterWall, 2, 2.1, -0.8)
        let posterB = slot("p:1", .poster, posterWall, 2, 2.2, 0.8)
        let coordinator = makeCoordinator(
            registry: registry,
            bars: bars,
            adapters: [.door: door, .poster: poster]
        )
        activate(
            coordinator,
            registry: registry,
            routes: [.door: [doorA, doorB], .poster: [posterA, posterB]],
            active: [.door: doorA, .poster: posterA],
            adapters: [.door: door, .poster: poster]
        )

        coordinator.begin(propID: .door, worldPoint: .zero)
        coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))
        coordinator.end(commit: true)
        coordinator.begin(propID: .poster, worldPoint: .zero)
        coordinator.update(worldPoint: SIMD3<Float>(0.066, 0, 0))
        coordinator.end(commit: true)

        XCTAssertEqual(door.commitCount, 1)
        XCTAssertEqual(poster.commitCount, 1)
        XCTAssertEqual(
            coordinator.activeSlotForTesting(propID: .door)?.slotID,
            doorB.slotID
        )
        XCTAssertEqual(
            coordinator.activeSlotForTesting(propID: .poster)?.slotID,
            posterB.slotID
        )
    }

    private struct SinglePropSetup {
        let coordinator: TuringStoryPlacementAdjustmentCoordinator
        let registry: WallPropOccupancyRegistry
        let bars: TuringStoryPlacementMockBars
        let adapter: TuringStoryPlacementMockAdapter
        let routes: [TuringStoryRuntimeSlot]
    }

    private func makeSinglePropSetup(
        activeIndex: Int
    ) -> SinglePropSetup {
        let registry = WallPropOccupancyRegistry()
        let bars = TuringStoryPlacementMockBars()
        let adapter = TuringStoryPlacementMockAdapter(
            propID: .window,
            occupancyRegistry: registry
        )
        let wall = UUID()
        let routes = [
            slot("w:0", .window, wall, 1, 1.1, -1.0),
            slot("w:1", .window, wall, 1, 1.2, 0.0),
            slot("w:2", .window, wall, 1, 1.3, 1.0),
        ]
        let coordinator = makeCoordinator(
            registry: registry,
            bars: bars,
            adapters: [.window: adapter]
        )
        activate(
            coordinator,
            registry: registry,
            routes: [.window: routes],
            active: [.window: routes[activeIndex]],
            adapters: [.window: adapter]
        )
        return SinglePropSetup(
            coordinator: coordinator,
            registry: registry,
            bars: bars,
            adapter: adapter,
            routes: routes
        )
    }

    private func makeCoordinator(
        registry: WallPropOccupancyRegistry,
        bars: TuringStoryPlacementMockBars,
        adapters: [TuringStoryPropID: TuringStoryPlacementMockAdapter]
    ) -> TuringStoryPlacementAdjustmentCoordinator {
        let erased = adapters.reduce(
            into: [
                TuringStoryPropID:
                    any TuringStoryAdjustablePlacementController
            ]()
        ) { result, pair in
            result[pair.key] = pair.value
        }
        return TuringStoryPlacementAdjustmentCoordinator(
            occupancyRegistry: registry,
            adapters: erased,
            bars: bars
        )
    }

    private func activate(
        _ coordinator: TuringStoryPlacementAdjustmentCoordinator,
        registry: WallPropOccupancyRegistry,
        routes: [TuringStoryPropID: [TuringStoryRuntimeSlot]],
        active: [TuringStoryPropID: TuringStoryRuntimeSlot],
        adapters: [TuringStoryPropID: TuringStoryPlacementMockAdapter]
    ) {
        for (propID, slot) in active {
            guard let adapter = adapters[propID] else { continue }
            registry.register(
                id: adapter.adjustmentOccupancyID,
                wallID: slot.wallID,
                kind: propID.occupancyKind,
                rect: slot.semanticReservation,
                padding: 0,
                label: "initial test \(propID.rawValue)"
            )
        }
        coordinator.activate(
            seed: TuringStoryPlacementTestFactory.seed(
                routes: routes,
                active: active
            )
        )
    }

    private func slot(
        _ id: String,
        _ propID: TuringStoryPropID,
        _ wallID: UUID,
        _ wallOrdinal: Int,
        _ routeOrder: Float,
        _ localX: Float
    ) -> TuringStoryRuntimeSlot {
        TuringStoryPlacementTestFactory.slot(
            id: id,
            propID: propID,
            wallID: wallID,
            wallOrdinal: wallOrdinal,
            routeOrder: routeOrder,
            localX: localX,
            localY: 1,
            width: 0.45,
            height: 0.45
        )
    }

    private func assertMatrix(
        _ lhs: simd_float4x4,
        equals rhs: simd_float4x4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThan(
            simd_length(lhs.columns.0 - rhs.columns.0),
            0.0001,
            file: file,
            line: line
        )
        XCTAssertLessThan(
            simd_length(lhs.columns.1 - rhs.columns.1),
            0.0001,
            file: file,
            line: line
        )
        XCTAssertLessThan(
            simd_length(lhs.columns.2 - rhs.columns.2),
            0.0001,
            file: file,
            line: line
        )
        XCTAssertLessThan(
            simd_length(lhs.columns.3 - rhs.columns.3),
            0.0001,
            file: file,
            line: line
        )
    }
}
