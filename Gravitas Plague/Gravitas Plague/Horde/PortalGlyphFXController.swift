import Foundation
import RealityKit
import simd

@MainActor
final class PortalGlyphFXController {
    let wallRoot = Entity()
    let floorRoot = Entity()

    private var wallEntities: [Entity] = []
    private var floorEntities: [Entity] = []

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
        tearDownEntitiesOnly()

        let library = PortalGlyphAssetLibrary.shared

        let wallPlacements = PortalGlyphLayoutEngine.generateWallPlacements(
            perimeterPoints: perimeterLocalPoints,
            seed: seed,
            library: library
        )

        for placement in wallPlacements {
            let entity = PortalGlyphDecalFactory.makeWallGlyph(
                placement: placement
            )

            wallRoot.addChild(entity)
            wallEntities.append(entity)
        }

        if wallRoot.parent == nil {
            portalRoot.addChild(wallRoot)
        }

        if let floorY {
            let portalWorldFromLocal = portalRoot.transformMatrix(
                relativeTo: nil
            )

            let floorPlacements = PortalGlyphLayoutEngine.generateFloorPlacements(
                seed: seed,
                library: library,
                portalWidth: portalWidth
            )

            for placement in floorPlacements {
                let entity = PortalGlyphDecalFactory.makeFloorGlyph(
                    placement: placement,
                    floorY: floorY,
                    portalWorldFromLocal: portalWorldFromLocal
                )

                floorRoot.addChild(entity)
                floorEntities.append(entity)
            }

            if floorRoot.parent == nil {
                sceneRoot.addChild(floorRoot)
            }
        }

        print(
            """
            [PortalGlyphs] FX built
              portalID: \(portalID)
              wallID: \(portalPlacement.wallID)
              wallGlyphs: \(wallEntities.count)
              floorGlyphs: \(floorEntities.count)
              seed: \(seed)
              pixelsPerMeter: \(PortalGlyphFXSettings.pixelsPerMeter)
              noRuntimeScale: true
              emissiveIntensity: \(PortalGlyphFXSettings.emissiveIntensity)
            """
        )
    }

    func teardown() {
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
