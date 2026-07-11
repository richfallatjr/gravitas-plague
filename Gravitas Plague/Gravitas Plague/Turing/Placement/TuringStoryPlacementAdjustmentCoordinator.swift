import Foundation
import RealityKit
import simd

@MainActor
final class TuringStoryPlacementAdjustmentCoordinator {
    private enum Tuning {
        static let candidateStepMeters: Float = 0.065
        static let hysteresisMeters: Float = 0.016
        static let snapDurationSeconds: TimeInterval = 0.20
        static let cancelDurationSeconds: TimeInterval = 0.18
    }

    private struct ActiveDrag {
        let propID: TuringStoryPropID
        let originalSlot: TuringStoryRuntimeSlot
        var route: [TuringStoryRuntimeSlot]
        var index: Int
        var lastWorldPoint: SIMD3<Float>
        let dragAxis: SIMD3<Float>
        var accumulatedMeters: Float
    }

    private let occupancyRegistry: WallPropOccupancyRegistry
    private let adapters: [TuringStoryPropID: any TuringStoryAdjustablePlacementController]
    private let bars: any TuringStoryPlacementAdjustmentBarPresenting

    private var cache = TuringStoryPlacementCandidateCache(slotsByProp: [:])
    private var activeSlotByProp: [TuringStoryPropID: TuringStoryRuntimeSlot] = [:]
    private var activeDrag: ActiveDrag?
    private(set) var activeScanID: String?

    init(
        occupancyRegistry: WallPropOccupancyRegistry,
        adapters: [TuringStoryPropID: any TuringStoryAdjustablePlacementController],
        bars: any TuringStoryPlacementAdjustmentBarPresenting
    ) {
        self.occupancyRegistry = occupancyRegistry
        self.adapters = adapters
        self.bars = bars
    }

    convenience init(
        wallProvider: any TuringStoryAdjustmentWallProviding,
        occupancyRegistry: WallPropOccupancyRegistry,
        adapters: [TuringStoryPropID: any TuringStoryAdjustablePlacementController]
    ) {
        self.init(
            occupancyRegistry: occupancyRegistry,
            adapters: adapters,
            bars: TuringStoryPlacementAdjustmentBarPresenter(
                wallProvider: wallProvider
            )
        )
    }

    func install(
        sceneRoot: Entity
    ) {
        bars.install(sceneRoot: sceneRoot)
    }

    func activate(
        seed: TuringStoryPlacementAdjustmentSeed
    ) {
        cancel(reason: "newPlacementSeed")

        let candidateCache = TuringStoryPlacementCandidateCache(
            slotsByProp: seed.candidatesByProp
        )
        var selected: [TuringStoryPropID: TuringStoryRuntimeSlot] = [:]

        do {
            for propID in TuringStoryPropID.allCases {
                guard let slotID = seed.initiallySelectedSlotIDByProp[propID] else {
                    continue
                }
                guard
                    let slot = candidateCache.slot(
                        propID: propID,
                        slotID: slotID
                    )
                else {
                    throw TuringStoryPlacementAdjustmentError.missingInitialSlot(
                        propID: propID,
                        slotID: slotID
                    )
                }
                guard let adapter = adapters[propID] else {
                    throw TuringStoryPlacementAdjustmentError.missingController(
                        propID
                    )
                }
                try adapter.adoptCommittedAdjustmentSlot(slot)
                selected[propID] = slot
            }
        } catch {
            cache = TuringStoryPlacementCandidateCache(slotsByProp: [:])
            activeSlotByProp.removeAll()
            activeScanID = nil
            bars.hideAll(reason: "seedActivationFailed")
            print(
                "[TuringPlacementAdjust] activation failed scanID=\(seed.scanID) error=\(error.localizedDescription)"
            )
            return
        }

        cache = candidateCache
        activeSlotByProp = selected
        activeScanID = seed.scanID
        bars.show(activeSlots: selected)
        refilterAllRoutesAfterCommit()

        print(
            "[TuringPlacementAdjust] activated scanID=\(seed.scanID) activeProps=\(selected.count)"
        )
    }

    func begin(
        propID: TuringStoryPropID,
        worldPoint: SIMD3<Float>
    ) {
        guard activeDrag == nil else {
            print(
                "[TuringPlacementAdjust] drag ignored prop=\(propID.rawValue) reason=anotherPropActive"
            )
            return
        }
        guard let adapter = adapters[propID],
            let current = activeSlotByProp[propID]
        else {
            return
        }

        var route = selectableRoute(
            propID: propID,
            adapter: adapter
        )
        if !route.contains(where: { $0.slotID == current.slotID }) {
            route.append(current)
            route.sort(by: routeSort)
        }
        guard
            let index = route.firstIndex(where: {
                $0.slotID == current.slotID
            })
        else {
            return
        }

        let rawAxis = bars.worldRightAxis(for: propID)
        let axisLength = simd_length(rawAxis)
        let axis =
            axisLength > 0.000_01
            ? rawAxis / axisLength
            : SIMD3<Float>(1, 0, 0)

        activeDrag = ActiveDrag(
            propID: propID,
            originalSlot: current,
            route: route,
            index: index,
            lastWorldPoint: worldPoint,
            dragAxis: axis,
            accumulatedMeters: 0
        )
        for otherPropID in TuringStoryPropID.allCases where otherPropID != propID {
            bars.setEnabled(false, propID: otherPropID)
        }
        bars.setVisualState(.pinched, propID: propID)

        print(
            """
            [TuringPlacementAdjust] drag began
              prop: \(propID.rawValue)
              currentSlot: \(current.slotID)
              selectableCandidates: \(route.count)
            """
        )
    }

    func update(
        worldPoint: SIMD3<Float>
    ) {
        guard var drag = activeDrag else {
            return
        }

        let delta = worldPoint - drag.lastWorldPoint
        drag.lastWorldPoint = worldPoint
        drag.accumulatedMeters += simd_dot(delta, drag.dragAxis)

        if drag.accumulatedMeters >= Tuning.candidateStepMeters {
            step(direction: 1, drag: &drag)
            drag.accumulatedMeters = -Tuning.hysteresisMeters
        } else if drag.accumulatedMeters <= -Tuning.candidateStepMeters {
            step(direction: -1, drag: &drag)
            drag.accumulatedMeters = Tuning.hysteresisMeters
        }

        activeDrag = drag
    }

    func end(
        commit: Bool
    ) {
        guard let drag = activeDrag,
            let adapter = adapters[drag.propID]
        else {
            activeDrag = nil
            return
        }

        defer {
            activeDrag = nil
            bars.setVisualState(.idle, propID: drag.propID)
            refilterAllRoutesAfterCommit()
        }

        guard commit else {
            adapter.cancelPlacementPreview()
            bars.preview(
                slot: drag.originalSlot,
                duration: Tuning.cancelDurationSeconds
            )
            print(
                """
                [TuringPlacementAdjust] cancelled
                  prop: \(drag.propID.rawValue)
                  restoredSlot: \(drag.originalSlot.slotID)
                """
            )
            return
        }

        let selected = drag.route[drag.index]
        do {
            try adapter.commitAdjustedPlacement(selected)
            activeSlotByProp[drag.propID] = selected
            bars.commit(slot: selected)
            print(
                """
                [TuringPlacementAdjust] committed
                  prop: \(drag.propID.rawValue)
                  slotID: \(selected.slotID)
                  wallOrdinal: \(selected.wallOrdinal)
                  occupancyUpdated: true
                """
            )
        } catch {
            adapter.cancelPlacementPreview()
            bars.preview(
                slot: drag.originalSlot,
                duration: Tuning.cancelDurationSeconds
            )
            print(
                "[TuringPlacementAdjust] commit failed prop=\(drag.propID.rawValue) error=\(error.localizedDescription)"
            )
        }
    }

    func cancel(
        reason: String
    ) {
        if let drag = activeDrag {
            adapters[drag.propID]?.cancelPlacementPreview()
            print(
                """
                [TuringPlacementAdjust] cancelled
                  prop: \(drag.propID.rawValue)
                  restoredSlot: \(drag.originalSlot.slotID)
                """
            )
        }
        activeDrag = nil
        activeScanID = nil
        activeSlotByProp.removeAll()
        cache = TuringStoryPlacementCandidateCache(slotsByProp: [:])
        bars.hideAll(reason: reason)
    }

    private func step(
        direction: Int,
        drag: inout ActiveDrag
    ) {
        guard !drag.route.isEmpty,
            let adapter = adapters[drag.propID]
        else {
            return
        }

        let previous = drag.route[drag.index]
        drag.index = TuringStoryPlacementRouteMath.wrappedIndex(
            current: drag.index,
            direction: direction,
            count: drag.route.count
        )
        let selected = drag.route[drag.index]

        adapter.previewPlannedPlacement(
            selected,
            duration: Tuning.snapDurationSeconds
        )
        bars.preview(
            slot: selected,
            duration: Tuning.snapDurationSeconds
        )
        bars.setVisualState(.snapping, propID: drag.propID)

        print(
            """
            [TuringPlacementAdjust] preview snapped
              prop: \(drag.propID.rawValue)
              fromSlot: \(previous.slotID)
              toSlot: \(selected.slotID)
              wallOrdinal: \(selected.wallOrdinal)
            """
        )
    }

    private func selectableRoute(
        propID: TuringStoryPropID,
        adapter: any TuringStoryAdjustablePlacementController
    ) -> [TuringStoryRuntimeSlot] {
        cache.slots(for: propID)
            .filter { slot in
                !occupancyRegistry.hasHardOverlap(
                    wallID: slot.wallID,
                    candidate: slot.semanticReservation,
                    candidateKind: propID.occupancyKind,
                    ignoredIDs: Set([adapter.adjustmentOccupancyID]),
                    emitDiagnostics: false
                )
            }
            .sorted(by: routeSort)
    }

    private func refilterAllRoutesAfterCommit() {
        for propID in TuringStoryPropID.allCases {
            guard let adapter = adapters[propID],
                activeSlotByProp[propID] != nil
            else {
                bars.setEnabled(false, propID: propID)
                continue
            }
            let route = selectableRoute(propID: propID, adapter: adapter)
            // A route with only the currently committed slot has nothing to
            // adjust. Keep the bar visible as a layout affordance but remove its
            // InputTarget until another prop move makes an alternative legal.
            let currentID = activeSlotByProp[propID]?.slotID
            let alternativeCount = route.filter {
                $0.slotID != currentID
            }.count
            bars.setEnabled(alternativeCount > 0, propID: propID)
        }
    }

    private func routeSort(
        lhs: TuringStoryRuntimeSlot,
        rhs: TuringStoryRuntimeSlot
    ) -> Bool {
        if lhs.wallOrdinal != rhs.wallOrdinal {
            return lhs.wallOrdinal < rhs.wallOrdinal
        }
        if abs(lhs.routeOrder - rhs.routeOrder) > 0.000_001 {
            return lhs.routeOrder < rhs.routeOrder
        }
        return lhs.slotID < rhs.slotID
    }

    // MARK: - Internal test inspection

    var activePropIDForTesting: TuringStoryPropID? {
        activeDrag?.propID
    }

    func activeSlotForTesting(
        propID: TuringStoryPropID
    ) -> TuringStoryRuntimeSlot? {
        activeSlotByProp[propID]
    }
}

