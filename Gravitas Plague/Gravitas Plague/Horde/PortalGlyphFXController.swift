import Foundation
import RealityKit
import simd

private struct PortalGlyphLayoutPlanInput: Sendable {
    let perimeterLocalPoints: [SIMD3<Float>]
    let seed: UInt64
    let library: PortalGlyphAssetLibrarySnapshot
    let includeFloor: Bool
}

private struct PortalGlyphLayoutPlan: Sendable {
    let wallPlacements: [PortalGlyphPlacementDescriptor]
    let floorPlacements: [PortalGlyphPlacementDescriptor]
}

private actor PortalGlyphLayoutPlannerEngine {
    func plan(
        input: PortalGlyphLayoutPlanInput
    ) -> PortalGlyphLayoutPlan {
        let wallPlacements = PortalGlyphLayoutEngine.generateWallPlacements(
            perimeterPoints: input.perimeterLocalPoints,
            seed: input.seed,
            library: input.library
        )

        let floorPlacements = input.includeFloor
            ? PortalGlyphLayoutEngine.generateFloorPlacementsFromBottomLine(
                perimeterPoints: input.perimeterLocalPoints,
                seed: input.seed,
                library: input.library
            )
            : []

        PortalGlyphLayoutEngine.validateCombinedPortalRules(
            placements: wallPlacements + floorPlacements
        )

        return PortalGlyphLayoutPlan(
            wallPlacements: wallPlacements,
            floorPlacements: floorPlacements
        )
    }
}

@MainActor
final class PortalGlyphFXController {
    let wallRoot = Entity()
    let floorRoot = Entity()

    private var wallEntities: [Entity] = []
    private var floorEntities: [Entity] = []
    private let layoutPlanner = PortalGlyphLayoutPlannerEngine()
    private var layoutTask: Task<Void, Never>?
    private var layoutRevision = 0

    private let portalID: UUID
    private let seed: UInt64

    init(
        portalID: UUID,
        seed: UInt64
    ) {
        self.portalID = portalID
        self.seed = seed

        wallRoot.name = "PortalGlyphWallRoot_\(portalID)"
        floorRoot.name = "PortalGlyphFloorRoot_\(portalID)"
    }

    func build(
        perimeterLocalPoints: [SIMD3<Float>],
        portalRoot: Entity,
        sceneRoot: Entity,
        floorY: Float?,
        portalPlacement: DoorPlacement,
        portalWidth: Float
    ) {
        PortalGlyphAssetLibrary.shared.loadIfNeeded()
        cancelLayoutTask()
        tearDownEntitiesOnly()

        let library = PortalGlyphAssetLibrary.shared
        let librarySnapshot = library.layoutSnapshot
        let includeFloor = floorY != nil
        let portalWorldFromLocal = includeFloor
            ? portalRoot.transformMatrix(relativeTo: nil)
            : nil
        let revision = layoutRevision
        let wallID = portalPlacement.wallID

        if wallRoot.parent == nil {
            portalRoot.addChild(wallRoot)
        }

        if includeFloor {
            if floorRoot.parent == nil {
                sceneRoot.addChild(floorRoot)
            }

            if floorRoot.parent === portalRoot {
                fatalError("[PortalGlyphs] floorRoot incorrectly parented to portalRoot")
            }

            if floorRoot.parent === wallRoot {
                fatalError("[PortalGlyphs] floorRoot incorrectly parented to wallRoot")
            }
        } else {
            print(
                """
                [PortalGlyphs] floor glyphs skipped
                  portalID: \(portalID)
                  reason: missing_detected_floor
                  action: no_floor_glyphs_on_wall
                """
            )
        }

        let input = PortalGlyphLayoutPlanInput(
            perimeterLocalPoints: perimeterLocalPoints,
            seed: seed,
            library: librarySnapshot,
            includeFloor: includeFloor
        )

        let planner = layoutPlanner

        layoutTask = Task { @MainActor [weak self] in
            let plan = await planner.plan(
                input: input
            )

            guard !Task.isCancelled else {
                return
            }

            self?.apply(
                plan: plan,
                revision: revision,
                floorY: floorY,
                portalWorldFromLocal: portalWorldFromLocal,
                wallID: wallID
            )
        }
    }

    private func apply(
        plan: PortalGlyphLayoutPlan,
        revision: Int,
        floorY: Float?,
        portalWorldFromLocal: simd_float4x4?,
        wallID: UUID
    ) {
        guard revision == layoutRevision else {
            return
        }

        layoutTask = nil

        let library = PortalGlyphAssetLibrary.shared
        let wallPlacements = plan.wallPlacements.compactMap {
            library.placement(
                from: $0
            )
        }
        let floorPlacements = plan.floorPlacements.compactMap {
            library.placement(
                from: $0
            )
        }

        if wallPlacements.count != plan.wallPlacements.count ||
            floorPlacements.count != plan.floorPlacements.count {
            print(
                """
                [PortalGlyphs] ERROR missing asset while resolving off-main layout
                  portalID: \(portalID)
                  expectedWall: \(plan.wallPlacements.count)
                  resolvedWall: \(wallPlacements.count)
                  expectedFloor: \(plan.floorPlacements.count)
                  resolvedFloor: \(floorPlacements.count)
                """
            )
        }

        for placement in wallPlacements {
            let entity = PortalGlyphDecalFactory.makeWallGlyph(
                placement: placement
            )

            wallRoot.addChild(entity)
            wallEntities.append(entity)
        }

        if let floorY,
           let portalWorldFromLocal {
            if floorPlacements.count > 1 {
                fatalError(
                    """
                    [PortalGlyphs] more than one floor glyph generated
                      count: \(floorPlacements.count)
                      maxAllowed: 1
                    """
                )
            }

            for placement in floorPlacements {
                if placement.asset.kind != .floor {
                    fatalError(
                        """
                        [PortalGlyphs] non-floor placement reached floor entity creation
                          file: \(placement.asset.fileName)
                          kind: \(placement.asset.kind.rawValue)
                        """
                    )
                }

                let entity = PortalGlyphDecalFactory.makeFloorGlyph(
                    placement: placement,
                    floorY: floorY,
                    portalWorldFromLocal: portalWorldFromLocal
                )

                floorRoot.addChild(entity)
                floorEntities.append(entity)
            }
        }

        print(
            """
            [PortalGlyphs] FX built
              portalID: \(portalID)
              wallID: \(wallID)
              wallGlyphs: \(wallEntities.count)
              floorGlyphs: \(floorEntities.count)
              seed: \(seed)
              pixelsPerFoot: \(PortalGlyphFXSettings.pixelsPerFoot)
              noRuntimeScale: true
              material: unlit_alpha_mask
              grid: false
              shelfRows: false
            """
        )
    }

    func teardown() {
        cancelLayoutTask()
        tearDownEntitiesOnly()
        wallRoot.removeFromParent()
        floorRoot.removeFromParent()

        print(
            """
            [PortalGlyphs] FX torn down
              portalID: \(portalID)
            """
        )
    }

    private func cancelLayoutTask() {
        layoutTask?.cancel()
        layoutTask = nil
        layoutRevision += 1
    }

    private func tearDownEntitiesOnly() {
        for child in wallRoot.children {
            child.removeFromParent()
        }

        for child in floorRoot.children {
            child.removeFromParent()
        }

        wallEntities.removeAll()
        floorEntities.removeAll()
    }
}

extension UUID {
    var uuidSeed: UInt64 {
        withUnsafeBytes(
            of: uuid
        ) { raw in
            var seed: UInt64 = 0
            let count = min(
                8,
                raw.count
            )

            for index in 0..<count {
                seed |= UInt64(raw[index]) << UInt64(index * 8)
            }

            return seed
        }
    }
}
