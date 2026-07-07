import Combine
import Foundation
import RealityKit
import simd
import UIKit

@MainActor
final class TuringStoryWalkieBundleController: ObservableObject {
    enum BundleError: LocalizedError {
        case missingUSDZ(String)
        case missingRequiredEntity(String)
        case noWallManager
        case noPlacement

        var errorDescription: String? {
            switch self {
            case .missingUSDZ(let name):
                return "Missing Story walkie bundle USDZ: \(name)"
            case .missingRequiredEntity(let name):
                return "Missing required Story walkie bundle entity: \(name)"
            case .noWallManager:
                return "Missing wall manager for Story walkie bundle placement."
            case .noPlacement:
                return "No valid wall placement for Story walkie bundle."
            }
        }
    }

    struct Anchors {
        let bundleRoot: Entity
        let shelf: Entity?
        let walkieRoot: Entity
        let walkieAudioEmitter: Entity
        let walkieIconAnchor: Entity
        let dadFrameRoot: Entity
        let dadFrameAudioEmitter: Entity
        let dadFrameIconAnchor: Entity
        let succulentRoot: Entity?
    }

    private(set) var root = Entity()
    private var loadedBundleRoot: Entity?
    private(set) var anchors: Anchors?

    private weak var wallManager: WallPlaneManager?
    private weak var occupancyRegistry: WallPropOccupancyRegistry?

    private let occupancyID = UUID()
    private(set) var placement: TuringStoryWallBundlePlacement?
    private(set) var isPlaced = false

    var walkieAudioEmitter: Entity? { anchors?.walkieAudioEmitter }
    var walkieIconAnchor: Entity? { anchors?.walkieIconAnchor }
    var dadFrameAudioEmitter: Entity? { anchors?.dadFrameAudioEmitter }
    var dadFrameIconAnchor: Entity? { anchors?.dadFrameIconAnchor }

    init() {
        root.name = "TuringStoryWalkieBundle_WorldRoot"
        root.isEnabled = false
    }

    func installIfNeeded(
        sceneRoot: Entity,
        wallManager: WallPlaneManager,
        occupancyRegistry: WallPropOccupancyRegistry
    ) {
        self.wallManager = wallManager
        self.occupancyRegistry = occupancyRegistry

        if root.parent == nil {
            sceneRoot.addChild(root)
        }

        print("[TuringWalkieBundle] installed")
    }

    func placeOnBestWallIfNeeded(
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) async -> Bool {
        guard !isPlaced else {
            return true
        }
        guard let wallManager else {
            print("[TuringWalkieBundle] ERROR missing wallManager")
            return false
        }

        do {
            let loadedRoot = try await loadBundleIfNeeded()
            let resolvedAnchors = try resolveAnchors(in: loadedRoot)
            anchors = resolvedAnchors

            guard let selectedPlacement = choosePlacement(
                wallManager: wallManager,
                playerPosition: playerPosition,
                playerForward: playerForward
            ) else {
                throw BundleError.noPlacement
            }

            guard let transform = worldTransform(
                placement: selectedPlacement,
                wallManager: wallManager
            ) else {
                throw BundleError.noPlacement
            }

            root.setTransformMatrix(transform, relativeTo: nil)
            root.isEnabled = true
            placement = selectedPlacement
            isPlaced = true

            registerOccupancy(placement: selectedPlacement)
            resolvedAnchors.walkieAudioEmitter.components.set(SpatialAudioComponent())
            resolvedAnchors.dadFrameAudioEmitter.components.set(SpatialAudioComponent())

            print("""
            [TuringWalkieBundle] placement committed
              wallID: \(selectedPlacement.wallID)
              localX: \(selectedPlacement.localX)
              localY: \(selectedPlacement.localY)
              width: \(selectedPlacement.width)
              height: \(selectedPlacement.height)
              preferredCenterHeightMeters: \(TuringStoryWalkieBundleTuning.preferredCenterHeightMeters)
              floorWorldY: \(selectedPlacement.floorWorldY.map { "\($0)" } ?? "nil")
              targetCenterWorldY: \(selectedPlacement.floorWorldY.map { "\($0 + TuringStoryWalkieBundleTuning.preferredCenterHeightMeters)" } ?? "nil")
              overlapsPoster: false
              overlapsPortal: false
              walkieAudioEmitter: \(resolvedAnchors.walkieAudioEmitter.name)
              dadFrameAudioEmitter: \(resolvedAnchors.dadFrameAudioEmitter.name)
            """)

            return true
        } catch {
            print("""
            [TuringWalkieBundle] ERROR placement failed
              error: \(error.localizedDescription)
            """)
            return false
        }
    }

    func reset(reason: String) {
        occupancyRegistry?.unregister(id: occupancyID)
        root.children.removeAll()
        root.isEnabled = false
        loadedBundleRoot = nil
        anchors = nil
        placement = nil
        isPlaced = false

        print("""
        [TuringWalkieBundle] reset
          reason: \(reason)
        """)
    }

    private func loadBundleIfNeeded() async throws -> Entity {
        if let loadedBundleRoot {
            return loadedBundleRoot
        }

        let url = Bundle.main.url(
            forResource: "turing_story_wall_bundle_v1",
            withExtension: "usdz",
            subdirectory: "Turing/Props"
        ) ?? Bundle.main.url(
            forResource: "turing_story_wall_bundle_v1",
            withExtension: "usdz"
        )

        guard let url else {
            throw BundleError.missingUSDZ("turing_story_wall_bundle_v1.usdz")
        }

        let entity = try await Entity(contentsOf: url)
        if entity.name.isEmpty {
            entity.name = "TuringStoryWallBundle_Root"
        }
        entity.scale = SIMD3<Float>(
            repeating: TuringStoryWalkieBundleTuning.assetImportScale
        )

        root.children.removeAll()
        root.addChild(entity)
        recenterLoadedBundleVisuals(entity)
        applyOcclusionPlaneMaterialIfPresent(
            in: entity,
            bundleURL: url
        )
        loadedBundleRoot = entity

        print("""
        [TuringWalkieBundle] USDZ loaded
          file: turing_story_wall_bundle_v1.usdz
          rootName: \(entity.name)
          assetImportScale: \(TuringStoryWalkieBundleTuning.assetImportScale)
        """)

        return entity
    }

    private func applyOcclusionPlaneMaterialIfPresent(
        in root: Entity,
        bundleURL: URL
    ) {
        guard let occlusionEntity = root.turingFindEntity(containingNormalized: "occlusion01") else {
            print("""
            [TuringWalkieBundle] occlusion mesh not found
              expectedEntityName: occlusion-01
              action: occlusion_mask_disabled
            """)
            return
        }

        guard let maskURL = resolveOcclusionMaskURL(bundleURL: bundleURL) else {
            occlusionEntity.isEnabled = false
            print("""
            [TuringWalkieBundle] occlusion mask texture not found
              entity: \(occlusionEntity.name)
              expectedSidecar: ao.png
              rule: white_opaque_black_transparent
              action: hide_occlusion_mesh_until_mask_exists
            """)
            return
        }

        do {
            let texture = try PortalGlyphMaskTextureCache.shared
                .textureForMaskPNG(url: maskURL)
            var material = UnlitMaterial()
            material.color = .init(
                tint: UIColor.black,
                texture: .init(texture)
            )
            material.blending = .transparent(
                opacity: .init(floatLiteral: 1.0)
            )
            material.faceCulling = .none

            let modelCount = overrideMaterialsRecursively(
                under: occlusionEntity,
                with: material
            )
            guard modelCount > 0 else {
                print("""
                [TuringWalkieBundle] occlusion mesh has no ModelComponent
                  entity: \(occlusionEntity.name)
                  action: occlusion_mask_disabled
                """)
                return
            }

            print("""
            [TuringWalkieBundle] occlusion mask material applied
              entity: \(occlusionEntity.name)
              texture: \(maskURL.lastPathComponent)
              rule: glyph_mask_white_opaque_black_transparent
              blackIsMask: false
              visibleColor: black
              material: unlit_alpha_mask
              faceCulling: none
              usdzAuthoredMaterialOverridden: true
              modelComponentsUpdated: \(modelCount)
              inputDisabled: true
            """)
        } catch {
            print("""
            [TuringWalkieBundle] ERROR occlusion mask material failed
              entity: \(occlusionEntity.name)
              texture: \(maskURL.lastPathComponent)
              error: \(error.localizedDescription)
              action: preserve_authored_material
            """)
        }
    }

    @discardableResult
    private func overrideMaterialsRecursively(
        under entity: Entity,
        with material: RealityKit.Material
    ) -> Int {
        var updatedCount = 0

        if var model = entity.components[ModelComponent.self] {
            model.materials = [material]
            entity.components.set(model)
            updatedCount += 1
        }

        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)

        for child in entity.children {
            updatedCount += overrideMaterialsRecursively(
                under: child,
                with: material
            )
        }

        return updatedCount
    }

    private func resolveOcclusionMaskURL(
        bundleURL: URL
    ) -> URL? {
        let directory = bundleURL.deletingLastPathComponent()
        let sidecarNames = [
            "ao",
            "occlusion-01",
            "occlusion_01",
            "TuringStoryWallBundle_Occlusion01"
        ]

        for name in sidecarNames {
            let url = directory
                .appendingPathComponent(name)
                .appendingPathExtension("png")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        for name in sidecarNames {
            if let url = Bundle.main.url(
                forResource: name,
                withExtension: "png",
                subdirectory: "Turing/Props"
            ) ?? Bundle.main.url(
                forResource: name,
                withExtension: "png"
            ) {
                return url
            }
        }

        return nil
    }

    private func recenterLoadedBundleVisuals(_ entity: Entity) {
        let bounds = root.visualBounds(
            recursive: true,
            relativeTo: root,
            excludeInactive: false
        )
        let centerY = bounds.center.y

        guard centerY.isFinite else {
            return
        }

        entity.position.y -= centerY

        print("""
        [TuringWalkieBundle] visual bounds recentered
          boundsCenterY: \(centerY)
          entityLocalYOffset: \(entity.position.y)
        """)
    }

    private func resolveAnchors(in root: Entity) throws -> Anchors {
        let walkieRoot = preferredPropRoot(
            exactName: "TuringStoryWalkieTalkie_Root",
            partialName: "Walkie",
            under: root,
            fallbackLocalPosition: SIMD3<Float>(0.18, 0.03, 0.02)
        )
        let dadFrameRoot = preferredPropRoot(
            exactName: "TuringStoryDadFrame_Root",
            partialName: "DadFrame",
            under: root,
            fallbackLocalPosition: SIMD3<Float>(-0.18, 0.08, 0.02)
        )

        let walkieAudioEmitter = proceduralAnchor(
            named: "TuringStoryWalkieTalkie_AudioEmitter",
            under: walkieRoot,
            fallbackLocalPosition: SIMD3<Float>(0, 0, 0.02)
        )
        let walkieIconAnchor = proceduralAnchor(
            named: "TuringStoryWalkieTalkie_IconAnchor",
            under: walkieRoot,
            fallbackLocalPosition: SIMD3<Float>(0, 0.08, 0.10)
        )
        let dadFrameAudioEmitter = proceduralAnchor(
            named: "TuringStoryDadFrame_AudioEmitter",
            under: dadFrameRoot,
            fallbackLocalPosition: SIMD3<Float>(0, 0, 0.02)
        )
        let dadFrameIconAnchor = proceduralAnchor(
            named: "TuringStoryDadFrame_IconAnchor",
            under: dadFrameRoot,
            fallbackLocalPosition: SIMD3<Float>(0, 0.10, 0.08)
        )

        let anchors = Anchors(
            bundleRoot: root,
            shelf: root.turingFindEntity(named: "TuringStoryWallBundle_Shelf"),
            walkieRoot: walkieRoot,
            walkieAudioEmitter: walkieAudioEmitter,
            walkieIconAnchor: walkieIconAnchor,
            dadFrameRoot: dadFrameRoot,
            dadFrameAudioEmitter: dadFrameAudioEmitter,
            dadFrameIconAnchor: dadFrameIconAnchor,
            succulentRoot: root.turingFindEntity(named: "TuringStorySucculent_Root")
        )

        print("""
        [TuringWalkieBundle] required anchors resolved
          walkieRoot: \(anchors.walkieRoot.name)
          walkieAudioEmitter: \(anchors.walkieAudioEmitter.name)
          walkieIconAnchor: \(anchors.walkieIconAnchor.name)
          dadFrameRoot: \(anchors.dadFrameRoot.name)
          dadFrameAudioEmitter: \(anchors.dadFrameAudioEmitter.name)
          dadFrameIconAnchor: \(anchors.dadFrameIconAnchor.name)
          shelf: \(anchors.shelf?.name ?? "nil")
          succulent: \(anchors.succulentRoot?.name ?? "nil")
        """)

        return anchors
    }

    private func preferredPropRoot(
        exactName: String,
        partialName: String,
        under root: Entity,
        fallbackLocalPosition: SIMD3<Float>
    ) -> Entity {
        if let exact = root.turingFindEntity(named: exactName) {
            return exact
        }

        if let partial = root.turingFindEntity(containing: partialName) {
            print("""
            [TuringWalkieBundle] root resolved by partial name
              expected: \(exactName)
              actual: \(partial.name)
            """)
            return partial
        }

        let entity = Entity()
        entity.name = exactName
        entity.position = fallbackLocalPosition
        root.addChild(entity)

        print("""
        [TuringWalkieBundle] procedural root added
          name: \(exactName)
          parent: \(root.name)
          localPosition: \(fallbackLocalPosition)
        """)

        return entity
    }

    private func proceduralAnchor(
        named name: String,
        under parent: Entity,
        fallbackLocalPosition: SIMD3<Float>
    ) -> Entity {
        if let existing = parent.turingFindEntity(named: name) {
            return existing
        }

        let entity = Entity()
        entity.name = name
        entity.position = fallbackLocalPosition
        parent.addChild(entity)

        print("""
        [TuringWalkieBundle] procedural anchor added
          name: \(name)
          parent: \(parent.name)
          localPosition: \(fallbackLocalPosition)
        """)

        return entity
    }

    private func choosePlacement(
        wallManager: WallPlaneManager,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> TuringStoryWallBundlePlacement? {
        let walls = wallManager.wallCandidates.values
            .filter {
                $0.width >= TuringStoryWalkieBundleTuning.defaultWidthMeters &&
                    $0.height >= TuringStoryWalkieBundleTuning.defaultHeightMeters
            }

        var best: (placement: TuringStoryWallBundlePlacement, score: Float)?

        for wall in walls {
            let width = TuringStoryWalkieBundleTuning.defaultWidthMeters
            let height = TuringStoryWalkieBundleTuning.defaultHeightMeters
            let floor = wallManager.bestFloorCandidate(near: wall)
            guard let floor else {
                print("""
                [TuringWalkieBundle] candidate rejected
                  wallID: \(wall.id)
                  reason: no_floor_candidate
                """)
                continue
            }

            let preferredCenter =
                floor.worldY +
                TuringStoryWalkieBundleTuning.preferredCenterHeightMeters
            let minCenter =
                floor.worldY +
                TuringStoryWalkieBundleTuning.minBottomClearanceMeters +
                height * 0.5
            let desiredWorldY = max(preferredCenter, minCenter)

            let desiredLocalY: Float
            if abs(wall.up.y) > 0.05 {
                desiredLocalY = (desiredWorldY - wall.center.y) / wall.up.y
            } else {
                print("""
                [TuringWalkieBundle] candidate rejected
                  wallID: \(wall.id)
                  reason: invalid_wall_up_for_floor_lock
                """)
                continue
            }

            let maxX = max(
                0,
                wall.width * 0.5 - width * 0.5 -
                    TuringStoryWalkieBundleTuning.wallMarginMeters
            )
            let maxY = max(
                0,
                wall.height * 0.5 - height * 0.5 -
                    TuringStoryWalkieBundleTuning.wallMarginMeters
            )
            let clampedY = min(max(desiredLocalY, -maxY), maxY)
            guard abs(clampedY - desiredLocalY) < 0.08 else {
                print("""
                [TuringWalkieBundle] candidate rejected
                  wallID: \(wall.id)
                  reason: floor_height_outside_wall_extent
                  desiredWorldY: \(desiredWorldY)
                  floorY: \(floor.worldY)
                  desiredLocalY: \(desiredLocalY)
                  clampedLocalY: \(clampedY)
                """)
                continue
            }
            let candidateXs: [Float] = [
                0,
                -maxX * 0.55,
                maxX * 0.55,
                -maxX,
                maxX
            ]

            for x in candidateXs {
                let placement = TuringStoryWallBundlePlacement(
                    wallID: wall.id,
                    localX: x,
                    localY: clampedY,
                    depthOffset: TuringStoryWalkieBundleTuning.depthOffset,
                    width: width,
                    height: height,
                    floorWorldY: floor.worldY
                )
                let rect = turingWalkieWallRect(for: placement)
                let expandedRect = rect.expanded(
                    by: TuringStoryWalkieBundleTuning.occupancyPaddingMeters
                )

                if occupancyRegistry?.hasHardOverlap(
                    wallID: wall.id,
                    candidate: expandedRect,
                    candidateKind: .storyWalkieBundle
                ) == true {
                    print("""
                    [TuringWalkieBundle] candidate rejected by wall occupancy
                      wallID: \(wall.id)
                      reason: overlaps_poster_or_portal
                    """)
                    continue
                }

                let toWall = turingNormalizeSafe(
                    wall.center - playerPosition,
                    fallback: SIMD3<Float>(0, 0, -1)
                )
                let forward = turingNormalizeSafe(
                    SIMD3<Float>(playerForward.x, 0, playerForward.z),
                    fallback: SIMD3<Float>(0, 0, -1)
                )
                let facingScore = max(0, simd_dot(toWall, forward))
                let posterDistance = occupancyRegistry?.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.wallPoster]
                ) ?? Float.greatestFiniteMagnitude
                let portalDistance = occupancyRegistry?.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.hordePortal, .storyPortal]
                ) ?? Float.greatestFiniteMagnitude
                let score =
                    facingScore * 4.0 +
                    wall.stabilityScore * 2.0 +
                    min(1, posterDistance) *
                        TuringStoryWalkieBundleTuning.posterAvoidanceWeight +
                    min(1, portalDistance) *
                        TuringStoryWalkieBundleTuning.portalAvoidanceWeight -
                    abs(x) * 0.20

                if best == nil || score > best!.score {
                    best = (placement, score)
                }
            }
        }

        return best?.placement
    }

    private func worldTransform(
        placement: TuringStoryWallBundlePlacement,
        wallManager: WallPlaneManager
    ) -> simd_float4x4? {
        guard let wall = wallManager.wallCandidates[placement.wallID] else {
            return nil
        }

        let position =
            wall.center +
            wall.right * placement.localX +
            wall.up * placement.localY +
            wall.normal * placement.depthOffset

        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(wall.right.x, wall.right.y, wall.right.z, 0)
        matrix.columns.1 = SIMD4<Float>(wall.up.x, wall.up.y, wall.up.z, 0)
        matrix.columns.2 = SIMD4<Float>(wall.normal.x, wall.normal.y, wall.normal.z, 0)
        matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return matrix
    }

    private func registerOccupancy(
        placement: TuringStoryWallBundlePlacement
    ) {
        occupancyRegistry?.unregister(id: occupancyID)
        occupancyRegistry?.register(
            id: occupancyID,
            wallID: placement.wallID,
            kind: .storyWalkieBundle,
            rect: turingWalkieWallRect(for: placement),
            padding: TuringStoryWalkieBundleTuning.occupancyPaddingMeters,
            label: "Turing Story walkie-talkie shelf bundle"
        )
    }
}

private extension Entity {
    func turingFindEntity(named targetName: String) -> Entity? {
        if name == targetName {
            return self
        }

        for child in children {
            if let found = child.turingFindEntity(named: targetName) {
                return found
            }
        }

        return nil
    }

    func turingFindEntity(containing token: String) -> Entity? {
        if name.localizedCaseInsensitiveContains(token) {
            return self
        }

        for child in children {
            if let found = child.turingFindEntity(containing: token) {
                return found
            }
        }

        return nil
    }

    func turingFindEntity(containingNormalized token: String) -> Entity? {
        if normalizedEntityName.contains(token) {
            return self
        }

        for child in children {
            if let found = child.turingFindEntity(containingNormalized: token) {
                return found
            }
        }

        return nil
    }

    var normalizedEntityName: String {
        name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private func turingNormalizeSafe(
    _ value: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(value)
    guard length > 0.0001 else {
        return fallback
    }
    return value / length
}
