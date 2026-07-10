import Combine
import Foundation
import RealityKit
import simd
import UIKit

@MainActor
final class TuringStoryWindowBundleController: ObservableObject {
    enum BundleError: LocalizedError {
        case missingUSDZ(String)
        case missingRequiredEntity(String)
        case noWallManager
        case noPlacement

        var errorDescription: String? {
            switch self {
            case .missingUSDZ(let name):
                return "Missing Story window bundle USDZ: \(name)"
            case .missingRequiredEntity(let name):
                return "Missing required Story window bundle entity: \(name)"
            case .noWallManager:
                return "Missing wall manager for Story window bundle placement."
            case .noPlacement:
                return "No valid wall placement for Story window bundle."
            }
        }
    }

    struct Anchors {
        let bundleRoot: Entity
        let frameRoot: Entity
        let glass: Entity
        let portalPlane: Entity
        let dayNightIconAnchor: Entity
        let placementBounds: Entity?
    }

    let root = Entity()
    private let portalWorldRoot = Entity()
    private var loadedBundleRoot: Entity?
    private(set) var anchors: Anchors?

    private weak var wallManager: WallPlaneManager?
    private weak var occupancyRegistry: WallPropOccupancyRegistry?

    private let occupancyID = UUID()
    private(set) var placement: TuringStoryWindowBundlePlacement?
    private(set) var isPlaced = false
    private var activeAtmosphere: PortalHDRIAtmosphere = .night
    private var loadedVisualMinY: Float = 0
    private var loadedVisualMaxY: Float = TuringStoryWindowBundleTuning
        .defaultHeightMeters

    init() {
        root.name = "TuringStoryWindowBundle_WorldRoot"
        root.isEnabled = false

        portalWorldRoot.name = "TuringStoryWindowPortalWorldRoot"
        portalWorldRoot.components.set(WorldComponent())
        root.addChild(portalWorldRoot)
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

        print("[TuringWindowPortal] installed")
    }

    func prepareForPlannedPlacement() async throws {
        let loadedRoot = try await loadBundleIfNeeded()
        anchors = try resolveAnchors(in: loadedRoot)
    }

    func commitPlannedPlacement(
        _ plannedPlacement: TuringStoryWindowBundlePlacement,
        semanticReservation: WallLocalRect,
        atmosphere: PortalHDRIAtmosphere
    ) async throws {
        guard let wallManager else { throw BundleError.noWallManager }
        if anchors == nil { try await prepareForPlannedPlacement() }
        guard let resolvedAnchors = anchors,
              let transform = worldTransform(
                placement: plannedPlacement,
                wallManager: wallManager
              ) else { throw BundleError.noPlacement }
        root.setTransformMatrix(transform, relativeTo: nil)
        root.isEnabled = true
        placement = plannedPlacement
        isPlaced = true
        activeAtmosphere = atmosphere
        registerOccupancy(
            placement: plannedPlacement,
            semanticReservation: semanticReservation
        )
        logBottomPlacementProof(placement: plannedPlacement, wallManager: wallManager)
        await bindRuntimeMaterialsAndPortal(
            anchors: resolvedAnchors,
            atmosphere: atmosphere,
            placement: plannedPlacement
        )
    }

    func placeOnBestWallIfNeeded(
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>,
        atmosphere: PortalHDRIAtmosphere
    ) async -> Bool {
        if isPlaced {
            await updateAtmosphereIfNeeded(atmosphere)
            return true
        }

        guard let wallManager else {
            print("[TuringWindowPortal] ERROR missing wallManager")
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

            root.setTransformMatrix(
                transform,
                relativeTo: nil
            )
            root.isEnabled = true
            placement = selectedPlacement
            isPlaced = true
            activeAtmosphere = atmosphere

            registerOccupancy(placement: selectedPlacement)
            logBottomPlacementProof(
                placement: selectedPlacement,
                wallManager: wallManager
            )
            await bindRuntimeMaterialsAndPortal(
                anchors: resolvedAnchors,
                atmosphere: atmosphere,
                placement: selectedPlacement
            )

            print(
                """
                [TuringWindowPortal] placement committed
                  wallID: \(selectedPlacement.wallID)
                  localX: \(selectedPlacement.localX)
                  localY: \(selectedPlacement.localY)
                  width: \(selectedPlacement.width)
                  height: \(selectedPlacement.height)
                  visualHeight: \(loadedVisualHeight)
                  preferredBottomHeightMeters: \(TuringStoryWindowBundleTuning.preferredBottomHeightMeters)
                  floorWorldY: \(selectedPlacement.floorWorldY.map { "\($0)" } ?? "nil")
                  heightPlacementSource: scanned_floor_visual_bottom_2_8ft_no_wall_y_clamp
                  overlapsPoster: false
                  overlapsPortal: false
                  atmosphere: \(atmosphere.rawValue)
                """
            )

            return true
        } catch {
            print(
                """
                [TuringWindowPortal] ERROR placement failed
                  error: \(error.localizedDescription)
                """
            )
            return false
        }
    }

    func updateAtmosphereIfNeeded(
        _ atmosphere: PortalHDRIAtmosphere
    ) async {
        guard let placement else {
            return
        }

        activeAtmosphere = atmosphere
        await reloadPortalWorld(
            atmosphere: atmosphere,
            placement: placement
        )

        print(
            """
            [TuringWindowPortal] atmosphere changed
              atmosphere: \(atmosphere.rawValue)
            """
        )
    }

    func reset(
        reason: String
    ) {
        occupancyRegistry?.unregister(id: occupancyID)
        root.children.removeAll()
        root.addChild(portalWorldRoot)
        root.isEnabled = false
        loadedBundleRoot = nil
        anchors = nil
        placement = nil
        isPlaced = false
        portalWorldRoot.children.removeAll()
        portalWorldRoot.components.set(WorldComponent())

        print(
            """
            [TuringWindowPortal] reset
              reason: \(reason)
            """
        )
    }

    private func loadBundleIfNeeded() async throws -> Entity {
        if let loadedBundleRoot {
            return loadedBundleRoot
        }

        let url = Bundle.main.url(
            forResource: "turing_story_window_bundle_v1",
            withExtension: "usdz",
            subdirectory: "Turing/Props"
        ) ?? Bundle.main.url(
            forResource: "turing_story_window_bundle_v1",
            withExtension: "usdz"
        )

        guard let url else {
            throw BundleError.missingUSDZ("turing_story_window_bundle_v1.usdz")
        }

        let entity = try await Entity(contentsOf: url)
        if entity.name.isEmpty {
            entity.name = "TuringStoryWindowBundle_Root"
        }
        entity.scale = SIMD3<Float>(
            repeating: TuringStoryWindowBundleTuning.assetImportScale
        )

        root.children.removeAll()
        root.addChild(entity)
        root.addChild(portalWorldRoot)
        updateLoadedVisualBounds()
        applyOcclusionPlaneMaterialIfPresent(
            in: entity,
            bundleURL: url
        )
        loadedBundleRoot = entity

        print(
            """
            [TuringWindowPortal] USDZ loaded
              file: turing_story_window_bundle_v1.usdz
              rootName: \(entity.name)
              assetImportScale: \(TuringStoryWindowBundleTuning.assetImportScale)
              visualMinY: \(loadedVisualMinY)
              visualMaxY: \(loadedVisualMaxY)
            """
        )

        return entity
    }

    private var loadedVisualHeight: Float {
        max(
            0.001,
            loadedVisualMaxY - loadedVisualMinY
        )
    }

    private var loadedVisualCenterY: Float {
        (loadedVisualMinY + loadedVisualMaxY) * 0.5
    }

    private func updateLoadedVisualBounds() {
        let bounds = root.visualBounds(
            recursive: true,
            relativeTo: root,
            excludeInactive: false
        )
        let minY = bounds.min.y
        let maxY = bounds.max.y

        guard minY.isFinite,
              maxY.isFinite,
              maxY > minY else {
            loadedVisualMinY = 0
            loadedVisualMaxY = TuringStoryWindowBundleTuning.defaultHeightMeters
            print(
                """
                [TuringWindowPortal] visual bounds unavailable; using tuning height
                  fallbackMinY: \(loadedVisualMinY)
                  fallbackMaxY: \(loadedVisualMaxY)
                """
            )
            return
        }

        loadedVisualMinY = minY
        loadedVisualMaxY = maxY

        print(
            """
            [TuringWindowPortal] visual bounds measured
              minY: \(loadedVisualMinY)
              maxY: \(loadedVisualMaxY)
              height: \(loadedVisualHeight)
            """
        )
    }

    private func applyOcclusionPlaneMaterialIfPresent(
        in root: Entity,
        bundleURL: URL
    ) {
        guard let occlusionEntity = root.turingWindowFindEntity(
            containingNormalized: "occlusion01"
        ) else {
            print(
                """
                [TuringWindowPortal] occlusion mesh not found
                  expectedEntityName: occlusion-01
                  action: occlusion_mask_disabled
                """
            )
            return
        }

        guard let maskURL = resolveOcclusionMaskURL(
            bundleURL: bundleURL
        ) else {
            occlusionEntity.isEnabled = false
            print(
                """
                [TuringWindowPortal] occlusion mask texture not found
                  entity: \(occlusionEntity.name)
                  expectedEmbedded: textures/ao.png
                  rule: white_opaque_black_transparent
                  action: hide_occlusion_mesh_until_embedded_mask_exists
                """
            )
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
                print(
                    """
                    [TuringWindowPortal] occlusion mesh has no ModelComponent
                      entity: \(occlusionEntity.name)
                      action: occlusion_mask_disabled
                    """
                )
                return
            }

            print(
                """
                [TuringWindowPortal] occlusion mask material applied
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
                """
            )
        } catch {
            print(
                """
                [TuringWindowPortal] ERROR occlusion mask material failed
                  entity: \(occlusionEntity.name)
                  texture: \(maskURL.lastPathComponent)
                  error: \(error.localizedDescription)
                  action: preserve_authored_material
                """
            )
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
        return extractEmbeddedOcclusionMaskURL(
            bundleURL: bundleURL
        )
    }

    private func extractEmbeddedOcclusionMaskURL(
        bundleURL: URL
    ) -> URL? {
        guard let archive = try? Data(
            contentsOf: bundleURL,
            options: .mappedIfSafe
        ) else {
            return nil
        }

        let targets: Set<String> = [
            "textures/ao.png",
            "ao.png"
        ]
        var offset = 0

        while offset + 30 <= archive.count {
            guard archive.turingWindowZIPUInt32(at: offset) == 0x04034b50 else {
                offset += 1
                continue
            }

            let compressionMethod = archive.turingWindowZIPUInt16(
                at: offset + 8
            )
            let compressedSize = Int(
                archive.turingWindowZIPUInt32(
                    at: offset + 18
                )
            )
            let uncompressedSize = Int(
                archive.turingWindowZIPUInt32(
                    at: offset + 22
                )
            )
            let fileNameLength = Int(
                archive.turingWindowZIPUInt16(
                    at: offset + 26
                )
            )
            let extraFieldLength = Int(
                archive.turingWindowZIPUInt16(
                    at: offset + 28
                )
            )
            let fileNameStart = offset + 30
            let fileNameEnd = fileNameStart + fileNameLength
            let dataStart = fileNameEnd + extraFieldLength
            let dataLength = compressedSize > 0
                ? compressedSize
                : uncompressedSize
            let dataEnd = dataStart + dataLength

            guard fileNameEnd <= archive.count,
                  dataStart <= archive.count else {
                return nil
            }

            let nameData = archive[fileNameStart..<fileNameEnd]
            let fileName = String(
                data: nameData,
                encoding: .utf8
            )?.lowercased()

            if let fileName,
               targets.contains(fileName),
               compressionMethod == 0,
               dataLength > 0,
               dataEnd <= archive.count {
                let outputURL = embeddedOcclusionMaskCacheURL(
                    bundleURL: bundleURL
                )

                do {
                    try archive
                        .subdata(in: dataStart..<dataEnd)
                        .write(
                            to: outputURL,
                            options: .atomic
                        )

                    print(
                        """
                        [TuringWindowPortal] embedded occlusion mask extracted
                          usdz: \(bundleURL.lastPathComponent)
                          embeddedPath: \(fileName)
                          output: \(outputURL.lastPathComponent)
                          source: embedded_usdz_texture
                        """
                    )

                    return outputURL
                } catch {
                    print(
                        """
                        [TuringWindowPortal] ERROR embedded occlusion mask extract failed
                          usdz: \(bundleURL.lastPathComponent)
                          embeddedPath: \(fileName)
                          error: \(error.localizedDescription)
                        """
                    )
                    return nil
                }
            }

            offset = max(
                offset + 1,
                dataEnd
            )
        }

        return nil
    }

    private func embeddedOcclusionMaskCacheURL(
        bundleURL: URL
    ) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: bundleURL.path
        )
        let fileSize = attributes?[.size] as? NSNumber
        let modified = attributes?[.modificationDate] as? Date
        let stamp = "\(fileSize?.intValue ?? 0)_\(Int(modified?.timeIntervalSince1970 ?? 0))"
        let name = "\(bundleURL.deletingPathExtension().lastPathComponent)_embedded_ao_\(stamp).png"

        return FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
    }

    private func resolveAnchors(
        in root: Entity
    ) throws -> Anchors {
        guard let frameRoot = root.turingWindowFindEntity(
            named: "TuringStoryWindowFrame_Root"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryWindowFrame_Root")
        }
        guard let glass = root.turingWindowFindEntity(
            named: "TuringStoryWindowGlass"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryWindowGlass")
        }
        guard let portalPlane = root.turingWindowFindEntity(
            named: "TuringStoryWindowPortalPlane"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryWindowPortalPlane")
        }
        let dayNightIconAnchor = proceduralAnchorIfMissing(
            named: "TuringStoryWindowDayNightIconAnchor",
            under: root,
            fallbackLocalPosition: SIMD3<Float>(0, -0.48, 0.08)
        )

        let anchors = Anchors(
            bundleRoot: root,
            frameRoot: frameRoot,
            glass: glass,
            portalPlane: portalPlane,
            dayNightIconAnchor: dayNightIconAnchor,
            placementBounds: root.turingWindowFindEntity(
                named: "TuringStoryWindowPlacementBounds"
            )
        )

        print(
            """
            [TuringWindowPortal] required anchors resolved
              frameRoot: \(anchors.frameRoot.name)
              glass: \(anchors.glass.name)
              portalPlane: \(anchors.portalPlane.name)
              dayNightIconAnchor: \(anchors.dayNightIconAnchor.name)
              placementBounds: \(anchors.placementBounds?.name ?? "nil")
            """
        )

        return anchors
    }

    private func proceduralAnchorIfMissing(
        named name: String,
        under parent: Entity,
        fallbackLocalPosition: SIMD3<Float>
    ) -> Entity {
        if let existing = parent.turingWindowFindEntity(named: name) {
            return existing
        }

        let entity = Entity()
        entity.name = name
        entity.position = fallbackLocalPosition
        parent.addChild(entity)

        print(
            """
            [TuringWindowPortal] procedural anchor added
              name: \(name)
              parent: \(parent.name)
              localPosition: \(fallbackLocalPosition)
              reason: non_visual_icon_anchor_missing_from_usdz
            """
        )

        return entity
    }

    private func bindRuntimeMaterialsAndPortal(
        anchors: Anchors,
        atmosphere: PortalHDRIAtmosphere,
        placement: TuringStoryWindowBundlePlacement
    ) async {
        TuringStoryWindowGlassMaterialFactory.applyGlassMaterialRecursively(
            to: anchors.glass
        )
        let portalModelCount = bindPortalComponentRecursively(
            to: anchors.portalPlane
        )

        await reloadPortalWorld(
            atmosphere: atmosphere,
            placement: placement
        )

        print(
            """
            [TuringWindowPortal] runtime materials bound
              glassMaterial: darkMatterHUDGlassStart
              portalMaterial: PortalMaterial
              portalModelComponentsUpdated: \(portalModelCount)
              portalTarget: TuringStoryWindowPortalWorldRoot
            """
        )
    }

    @discardableResult
    private func bindPortalComponentRecursively(
        to entity: Entity
    ) -> Int {
        var boundCount = 0

        if var model = entity.components[ModelComponent.self] {
            model.materials = [PortalMaterial()]
            entity.components.set(model)
            entity.components.set(
                PortalComponent(
                    target: portalWorldRoot
                )
            )
            boundCount += 1
        }

        for child in entity.children {
            boundCount += bindPortalComponentRecursively(
                to: child
            )
        }

        if boundCount == 0 {
            entity.components.set(
                PortalComponent(
                    target: portalWorldRoot
                )
            )
        }

        return boundCount
    }

    private func reloadPortalWorld(
        atmosphere: PortalHDRIAtmosphere,
        placement: TuringStoryWindowBundlePlacement
    ) async {
        let provider = TuringStoryWindowPortalContentProvider(
            atmosphere: atmosphere,
            worldYawRadians: placement.worldYawRadians
        )

        do {
            try await provider.populatePortalWorld(
                portalWorld: portalWorldRoot,
                context: .forDoor(
                    width: placement.width,
                    height: placement.height
                )
            )
        } catch {
            print(
                """
                [TuringWindowPortal] ERROR portal world reload failed
                  atmosphere: \(atmosphere.rawValue)
                  error: \(error.localizedDescription)
                """
            )
        }
    }

    private func choosePlacement(
        wallManager: WallPlaneManager,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> TuringStoryWindowBundlePlacement? {
        let walls = wallManager.wallCandidates.values
            .filter {
                $0.width >= TuringStoryWindowBundleTuning.defaultWidthMeters &&
                    $0.height >= TuringStoryWindowBundleTuning.defaultHeightMeters
            }

        var best: (placement: TuringStoryWindowBundlePlacement, score: Float)?

        for wall in walls {
            let width = TuringStoryWindowBundleTuning.defaultWidthMeters
            let height = TuringStoryWindowBundleTuning.defaultHeightMeters
            guard let floor = wallManager.bestFloorCandidate(near: wall) else {
                print(
                    """
                    [TuringWindowPortal] candidate rejected
                      wallID: \(wall.id)
                      reason: no_scanned_floor_for_deterministic_window_height
                    """
                )
                continue
            }
            let preferredBottom =
                floor.worldY +
                TuringStoryWindowBundleTuning.preferredBottomHeightMeters
            let minBottom =
                floor.worldY +
                TuringStoryWindowBundleTuning.minBottomClearanceMeters
            let desiredWorldY = max(preferredBottom, minBottom) + height * 0.5

            let desiredLocalY: Float
            if abs(wall.up.y) > 0.05 {
                desiredLocalY = (desiredWorldY - wall.center.y) / wall.up.y
            } else {
                desiredLocalY = 0
            }

            let maxX = max(
                0,
                wall.width * 0.5 - width * 0.5 -
                    TuringStoryWindowBundleTuning.wallMarginMeters
            )
            let candidateXs: [Float] = [
                0,
                -maxX * 0.55,
                maxX * 0.55,
                -maxX,
                maxX
            ]

            for x in candidateXs {
                let placement = TuringStoryWindowBundlePlacement(
                    wallID: wall.id,
                    localX: x,
                    localY: desiredLocalY,
                    depthOffset: TuringStoryWindowBundleTuning.depthOffset,
                    width: width,
                    height: height,
                    floorWorldY: floor.worldY,
                    worldYawRadians: worldYawRadians(wall: wall)
                )
                let rect = turingWindowWallRect(for: placement)
                let expandedRect = rect.expanded(
                    by: TuringStoryWindowBundleTuning.occupancyPaddingMeters
                )

                if occupancyRegistry?.hasHardOverlap(
                    wallID: wall.id,
                    candidate: expandedRect,
                    candidateKind: .storyWindowBundle
                ) == true {
                    print(
                        """
                        [TuringWindowPortal] candidate rejected by wall occupancy
                          wallID: \(wall.id)
                          reason: overlaps_poster_or_portal
                        """
                    )
                    continue
                }

                let toWall = turingWindowNormalizeSafe(
                    wall.center - playerPosition,
                    fallback: SIMD3<Float>(0, 0, -1)
                )
                let forward = turingWindowNormalizeSafe(
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
                let walkieDistance = occupancyRegistry?.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.storyWalkieBundle]
                ) ?? Float.greatestFiniteMagnitude
                let score =
                    facingScore * 4.0 +
                    wall.stabilityScore * 2.0 +
                    min(1, posterDistance) *
                        TuringStoryWindowBundleTuning.posterAvoidanceWeight +
                    min(1, portalDistance) *
                        TuringStoryWindowBundleTuning.portalAvoidanceWeight +
                    min(1, walkieDistance) *
                        TuringStoryWindowBundleTuning.walkieAvoidanceWeight -
                    abs(x) * 0.20

                if best == nil || score > best!.score {
                    best = (placement, score)
                }
            }
        }

        return best?.placement
    }

    private func worldTransform(
        placement: TuringStoryWindowBundlePlacement,
        wallManager: WallPlaneManager
    ) -> simd_float4x4? {
        guard let wall = wallManager.wallCandidates[placement.wallID] else {
            return nil
        }

        let position =
            wall.center +
            wall.right * placement.localX +
            wall.up * groundedRootLocalY(
                placement: placement,
                wall: wall
            ) +
            wall.normal * placement.depthOffset

        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(wall.right.x, wall.right.y, wall.right.z, 0)
        matrix.columns.1 = SIMD4<Float>(wall.up.x, wall.up.y, wall.up.z, 0)
        matrix.columns.2 = SIMD4<Float>(wall.normal.x, wall.normal.y, wall.normal.z, 0)
        matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return matrix
    }

    private func logBottomPlacementProof(
        placement: TuringStoryWindowBundlePlacement,
        wallManager: WallPlaneManager
    ) {
        guard let wall = wallManager.wallCandidates[placement.wallID] else {
            return
        }

        let rootPosition =
            wall.center +
            wall.right * placement.localX +
            wall.up * groundedRootLocalY(
                placement: placement,
                wall: wall
            ) +
            wall.normal * placement.depthOffset
        let visualBottomWorld =
            rootPosition +
            wall.up * loadedVisualMinY
        let expectedBottomWorldY = placement.floorWorldY.map {
            $0 + TuringStoryWindowBundleTuning.preferredBottomHeightMeters
        }

        print(
            """
            [TuringWindowPortal] floor-relative placement proof
              visualBottomWorldY: \(visualBottomWorld.y)
              floorWorldY: \(placement.floorWorldY.map { "\($0)" } ?? "nil")
              expectedBottomWorldY: \(expectedBottomWorldY.map { "\($0)" } ?? "nil")
              bottomHeightAboveFloorMeters: \(placement.floorWorldY.map { "\(visualBottomWorld.y - $0)" } ?? "nil")
              preferredBottomHeightMeters: \(TuringStoryWindowBundleTuning.preferredBottomHeightMeters)
              visualMinY: \(loadedVisualMinY)
              visualMaxY: \(loadedVisualMaxY)
              visualCenterY: \(loadedVisualCenterY)
            """
        )
    }

    private func groundedRootLocalY(
        placement: TuringStoryWindowBundlePlacement,
        wall: WallCandidate
    ) -> Float {
        guard let floorWorldY = placement.floorWorldY,
              abs(wall.up.y) > 0.05 else {
            return placement.localY - loadedVisualCenterY
        }

        let targetBottomWorldY =
            floorWorldY +
            TuringStoryWindowBundleTuning.preferredBottomHeightMeters

        return (targetBottomWorldY - wall.center.y) / wall.up.y -
            loadedVisualMinY
    }

    private func registerOccupancy(
        placement: TuringStoryWindowBundlePlacement,
        semanticReservation: WallLocalRect? = nil
    ) {
        occupancyRegistry?.unregister(id: occupancyID)
        occupancyRegistry?.register(
            id: occupancyID,
            wallID: placement.wallID,
            kind: .storyWindowBundle,
            rect: semanticReservation ?? turingWindowWallRect(for: placement),
            padding: semanticReservation == nil
                ? TuringStoryWindowBundleTuning.occupancyPaddingMeters : 0,
            label: "Turing Story window portal bundle"
        )
    }

    private func worldYawRadians(
        wall: WallCandidate
    ) -> Float {
        let wallForward = turingWindowNormalizeSafe(
            wall.normal,
            fallback: SIMD3<Float>(0, 0, 1)
        )
        return atan2(
            wallForward.x,
            wallForward.z
        )
    }
}

private extension Entity {
    func turingWindowFindEntity(
        named targetName: String
    ) -> Entity? {
        if name == targetName {
            return self
        }

        for child in children {
            if let found = child.turingWindowFindEntity(named: targetName) {
                return found
            }
        }

        return nil
    }

    func turingWindowFindEntity(
        containingNormalized token: String
    ) -> Entity? {
        if normalizedWindowEntityName.contains(token) {
            return self
        }

        for child in children {
            if let found = child.turingWindowFindEntity(
                containingNormalized: token
            ) {
                return found
            }
        }

        return nil
    }

    var normalizedWindowEntityName: String {
        name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private extension Data {
    func turingWindowZIPUInt16(
        at offset: Int
    ) -> UInt16 {
        guard offset + 2 <= count else {
            return 0
        }

        return UInt16(self[offset]) |
            (UInt16(self[offset + 1]) << 8)
    }

    func turingWindowZIPUInt32(
        at offset: Int
    ) -> UInt32 {
        guard offset + 4 <= count else {
            return 0
        }

        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}

private func turingWindowNormalizeSafe(
    _ v: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(v)
    guard length > 0.00001 else {
        return fallback
    }

    return v / length
}
