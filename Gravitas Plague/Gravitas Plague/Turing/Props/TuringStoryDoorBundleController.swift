import Combine
import Foundation
import RealityKit
import simd
import UIKit

@MainActor
final class TuringStoryDoorBundleController: ObservableObject {
    enum BundleError: LocalizedError {
        case missingUSDZ(String)
        case missingRequiredEntity(String)
        case noWallManager
        case noPlacement

        var errorDescription: String? {
            switch self {
            case .missingUSDZ(let name):
                return "Missing Story door bundle USDZ: \(name)"
            case .missingRequiredEntity(let name):
                return "Missing required Story door bundle entity: \(name)"
            case .noWallManager:
                return "Missing wall manager for Story door bundle placement."
            case .noPlacement:
                return "No valid wall placement for Story door bundle."
            }
        }
    }

    private struct DoorConfig: Codable {
        var schemaVersion: Int
        var bundleID: String
        var usdz: String
        var defaultOpenYawDegrees: Float
        var openDurationSeconds: Double
        var closeDurationSeconds: Double
        var preferredCenterHeightMeters: Float
        var defaultWidthMeters: Float
        var defaultHeightMeters: Float
        var defaultDepthOffsetMeters: Float
        var occupancyPaddingMeters: Float
        var portalWorldProvider: String
        var occlusionEnabled: Bool
        var sfx: SFXConfig

        struct SFXConfig: Codable {
            var open: String
            var closeSqueak: String
            var closeContact: String
        }

        static let fallback = DoorConfig(
            schemaVersion: 1,
            bundleID: "turing_story_door_bundle_v1",
            usdz: "turing_story_door_bundle_v1.usdz",
            defaultOpenYawDegrees: -145.0,
            openDurationSeconds: 1.15,
            closeDurationSeconds: 0.95,
            preferredCenterHeightMeters: TuringStoryDoorBundleTuning
                .preferredCenterHeightMeters,
            defaultWidthMeters: TuringStoryDoorBundleTuning.defaultWidthMeters,
            defaultHeightMeters: TuringStoryDoorBundleTuning.defaultHeightMeters,
            defaultDepthOffsetMeters: TuringStoryDoorBundleTuning.depthOffset,
            occupancyPaddingMeters: TuringStoryDoorBundleTuning
                .occupancyPaddingMeters,
            portalWorldProvider: TuringStoryDoorPortalContentProvider.providerID,
            occlusionEnabled: true,
            sfx: SFXConfig(
                open: "door-open-creak-01.wav",
                closeSqueak: "door-close-squeak-01.wav",
                closeContact: "door-close-contact-01.wav"
            )
        )
    }

    struct Anchors {
        let bundleRoot: Entity
        let frameRoot: Entity
        let hingePivot: Entity
        let doorPanelRoot: Entity
        let portalPlane: Entity
        let iconAnchor: Entity
        let audioEmitter: Entity
        let placementBounds: Entity?
        let glass: Entity?
        let portalSlab: Entity?
    }

    let root = Entity()
    private let portalWorldRoot = Entity()
    private var loadedBundleRoot: Entity?
    private(set) var anchors: Anchors?

    private weak var wallManager: WallPlaneManager?
    private weak var occupancyRegistry: WallPropOccupancyRegistry?

    private let occupancyID = UUID()
    private var config = DoorConfig.fallback
    private(set) var placement: TuringStoryDoorBundlePlacement?
    private(set) var isPlaced = false
    private var activeAtmosphere: PortalHDRIAtmosphere = .night
    private var animationController: TuringStoryDoorAnimationController?
    private let iconController = TuringStoryDoorIconController()
    private var loadedVisualMinY: Float = 0
    private var loadedVisualMaxY: Float = TuringStoryDoorBundleTuning
        .defaultHeightMeters

    init() {
        root.name = "TuringStoryDoorBundle_WorldRoot"
        root.isEnabled = false

        portalWorldRoot.name = "TuringStoryDoorPortalWorldRoot"
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

        print("[TuringDoorBundle] installed")
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
            print("[TuringDoorBundle] ERROR missing wallManager")
            return false
        }

        do {
            config = loadConfig()
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
            logFloorSnapProof(
                placement: selectedPlacement,
                wallManager: wallManager
            )
            await bindRuntimeMaterialsAndPortal(
                anchors: resolvedAnchors,
                atmosphere: atmosphere,
                placement: selectedPlacement
            )
            installAnimationController(anchors: resolvedAnchors)
            iconController.install(anchor: resolvedAnchors.iconAnchor)

            print(
                """
                [TuringDoorBundle] placement committed
                  wallID: \(selectedPlacement.wallID)
                  localX: \(selectedPlacement.localX)
                  localY: \(selectedPlacement.localY)
                  width: \(selectedPlacement.width)
                  height: \(selectedPlacement.height)
                  floorWorldY: \(selectedPlacement.floorWorldY.map { "\($0)" } ?? "nil")
                  visualHeight: \(loadedVisualHeight)
                  heightPlacementSource: scanned_floor_snap_no_visual_height_reject
                  preferredCenterHeightMeters: \(config.preferredCenterHeightMeters)
                  overlapsPoster: false
                  overlapsPortal: false
                  atmosphere: \(atmosphere.rawValue)
                """
            )

            return true
        } catch {
            print(
                """
                [TuringDoorBundle] ERROR placement failed
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
            [TuringDoorPortal] atmosphere changed
              atmosphere: \(atmosphere.rawValue)
            """
        )
    }

    func toggleDoor(
        reason: String
    ) {
        print(
            """
            [TuringDoorTrigger] tapped
              doorID: storyDoor.primary
              reason: \(reason)
            """
        )
        animationController?.toggle(reason: reason)
    }

    func reset(
        reason: String
    ) {
        animationController?.cancel(reason: reason)
        animationController = nil
        iconController.remove()
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
            [TuringDoorBundle] reset
              reason: \(reason)
            """
        )
    }

    private func loadConfig() -> DoorConfig {
        let url = Bundle.main.url(
            forResource: "turing_story_door_bundle_v1",
            withExtension: "json",
            subdirectory: "Turing/Props"
        ) ?? Bundle.main.url(
            forResource: "turing_story_door_bundle_v1",
            withExtension: "json"
        )

        guard let url else {
            print(
                """
                [TuringDoorBundle] config missing; using defaults
                  file: turing_story_door_bundle_v1.json
                """
            )
            return .fallback
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(
                DoorConfig.self,
                from: data
            )
            return decoded
        } catch {
            print(
                """
                [TuringDoorBundle] ERROR config decode failed; using defaults
                  file: turing_story_door_bundle_v1.json
                  error: \(error.localizedDescription)
                """
            )
            return .fallback
        }
    }

    private func loadBundleIfNeeded() async throws -> Entity {
        if let loadedBundleRoot {
            return loadedBundleRoot
        }

        let url = Bundle.main.url(
            forResource: "turing_story_door_bundle_v1",
            withExtension: "usdz",
            subdirectory: "Turing/Props"
        ) ?? Bundle.main.url(
            forResource: "turing_story_door_bundle_v1",
            withExtension: "usdz"
        )

        guard let url else {
            throw BundleError.missingUSDZ("turing_story_door_bundle_v1.usdz")
        }

        let entity = try await Entity(contentsOf: url)
        if entity.name.isEmpty || entity.name == "root" {
            entity.name = "TuringStoryDoorBundle_Root"
        }
        entity.scale = SIMD3<Float>(
            repeating: TuringStoryDoorBundleTuning.assetImportScale
        )

        root.children.removeAll()
        root.addChild(entity)
        root.addChild(portalWorldRoot)
        updateLoadedVisualBounds()
        prunePortalSlabFromPassthroughIfPresent(in: entity)
        applyOcclusionPlaneMaterialIfPresent(
            in: entity,
            bundleURL: url
        )
        loadedBundleRoot = entity

        print(
            """
            [TuringDoorBundle] USDZ loaded
              file: turing_story_door_bundle_v1.usdz
              rootName: \(entity.name)
              assetImportScale: \(TuringStoryDoorBundleTuning.assetImportScale)
              visualMinY: \(loadedVisualMinY)
              visualMaxY: \(loadedVisualMaxY)
            """
        )

        return entity
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
            loadedVisualMaxY = config.defaultHeightMeters
            print(
                """
                [TuringDoorBundle] visual bounds unavailable; using config height
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
            [TuringDoorBundle] visual bounds measured
              minY: \(loadedVisualMinY)
              maxY: \(loadedVisualMaxY)
              height: \(loadedVisualHeight)
            """
        )
    }

    private var loadedVisualCenterY: Float {
        (loadedVisualMinY + loadedVisualMaxY) * 0.5
    }

    private var loadedVisualHeight: Float {
        max(0.001, loadedVisualMaxY - loadedVisualMinY)
    }

    private func applyOcclusionPlaneMaterialIfPresent(
        in root: Entity,
        bundleURL: URL
    ) {
        guard let occlusionEntity =
                root.turingDoorFindEntity(containingNormalized: "occlusion01") ??
                root.turingDoorFindEntity(containingNormalized: "occlusion")
        else {
            print(
                """
                [TuringDoorPortal] occlusion mesh not found
                  expectedEntityName: occlusion-01
                  fallbackEntityName: occlusion
                  action: occlusion_mask_disabled
                """
            )
            return
        }

        guard let maskURL = extractEmbeddedOcclusionMaskURL(
            bundleURL: bundleURL
        ) else {
            occlusionEntity.isEnabled = false
            print(
                """
                [TuringDoorPortal] occlusion mask texture not found
                  entity: \(occlusionEntity.name)
                  expectedEmbedded: textures/ao.png
                  fallbackEmbedded: ao.png
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
                    [TuringDoorPortal] occlusion mesh has no ModelComponent
                      entity: \(occlusionEntity.name)
                      action: occlusion_mask_disabled
                    """
                )
                return
            }

            print(
                """
                [TuringDoorPortal] occlusion mask material applied
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
                [TuringDoorPortal] ERROR occlusion mask material failed
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
            guard archive.turingDoorZIPUInt32(at: offset) == 0x04034b50 else {
                offset += 1
                continue
            }

            let compressionMethod = archive.turingDoorZIPUInt16(
                at: offset + 8
            )
            let compressedSize = Int(
                archive.turingDoorZIPUInt32(
                    at: offset + 18
                )
            )
            let uncompressedSize = Int(
                archive.turingDoorZIPUInt32(
                    at: offset + 22
                )
            )
            let fileNameLength = Int(
                archive.turingDoorZIPUInt16(
                    at: offset + 26
                )
            )
            let extraFieldLength = Int(
                archive.turingDoorZIPUInt16(
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
                        [TuringDoorPortal] embedded occlusion mask extracted
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
                        [TuringDoorPortal] ERROR embedded occlusion mask extract failed
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
        guard let frameRoot = root.turingDoorFindEntity(
            named: "TuringStoryDoorFrame_Root"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryDoorFrame_Root")
        }
        guard let hingePivot = root.turingDoorFindEntity(
            named: "TuringStoryDoorHingePivot"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryDoorHingePivot")
        }
        guard let doorPanelRoot = root.turingDoorFindEntity(
            named: "TuringStoryDoorPanel_Root"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryDoorPanel_Root")
        }
        guard let portalPlane = root.turingDoorFindEntity(
            named: "TuringStoryDoorPortalPlane"
        ) else {
            throw BundleError.missingRequiredEntity("TuringStoryDoorPortalPlane")
        }
        let portalSlab = root.turingDoorFindEntity(
            named: "TuringStoryDoorPortalSlab_Root"
        )
        let iconAnchor = proceduralAnchorIfMissing(
            named: "TuringStoryDoorIconAnchor",
            under: root,
            fallbackLocalPosition: SIMD3<Float>(0, 1.18, 0.08)
        )
        let audioEmitter = proceduralAnchorIfMissing(
            named: "TuringStoryDoorAudioEmitter",
            under: root,
            fallbackLocalPosition: SIMD3<Float>(-0.42, 0.95, 0.06)
        )

        ensureDoorPanelIsChildOfHinge(
            doorPanelRoot: doorPanelRoot,
            hingePivot: hingePivot
        )

        let anchors = Anchors(
            bundleRoot: root,
            frameRoot: frameRoot,
            hingePivot: hingePivot,
            doorPanelRoot: doorPanelRoot,
            portalPlane: portalPlane,
            iconAnchor: iconAnchor,
            audioEmitter: audioEmitter,
            placementBounds: root.turingDoorFindEntity(
                named: "TuringStoryDoorPlacementBounds"
            ),
            glass: root.turingDoorFindEntity(
                named: "TuringStoryDoorGlass"
            ),
            portalSlab: portalSlab
        )

        print(
            """
            [TuringDoorBundle] required anchors resolved
              frameRoot: \(anchors.frameRoot.name)
              hingePivot: \(anchors.hingePivot.name)
              doorPanelRoot: \(anchors.doorPanelRoot.name)
              portalPlane: \(anchors.portalPlane.name)
              iconAnchor: \(anchors.iconAnchor.name)
              audioEmitter: \(anchors.audioEmitter.name)
              placementBounds: \(anchors.placementBounds?.name ?? "nil")
              portalSlab: \(anchors.portalSlab?.name ?? "nil")
              portalSource: authored
            """
        )

        return anchors
    }

    private func proceduralAnchorIfMissing(
        named name: String,
        under parent: Entity,
        fallbackLocalPosition: SIMD3<Float>
    ) -> Entity {
        if let existing = parent.turingDoorFindEntity(named: name) {
            return existing
        }

        let entity = Entity()
        entity.name = name
        entity.position = fallbackLocalPosition
        parent.addChild(entity)

        print(
            """
            [TuringDoorBundle] procedural anchor added
              name: \(name)
              parent: \(parent.name)
              localPosition: \(fallbackLocalPosition)
              reason: non_visual_anchor_missing_from_usdz
            """
        )

        return entity
    }

    private func ensureDoorPanelIsChildOfHinge(
        doorPanelRoot: Entity,
        hingePivot: Entity
    ) {
        if let parent = doorPanelRoot.parent,
           parent === hingePivot {
            return
        }

        doorPanelRoot.setParent(
            hingePivot,
            preservingWorldTransform: true
        )

        print(
            """
            [TuringDoorBundle] door panel reparented to hinge pivot
              hingePivot: TuringStoryDoorHingePivot
              doorPanelRoot: TuringStoryDoorPanel_Root
              preservingWorldTransform: true
              reason: authored_panel_was_not_child_of_hinge
            """
        )
    }

    private func bindRuntimeMaterialsAndPortal(
        anchors: Anchors,
        atmosphere: PortalHDRIAtmosphere,
        placement: TuringStoryDoorBundlePlacement
    ) async {
        if let glass = anchors.glass {
            TuringStoryWindowGlassMaterialFactory.applyGlassMaterialRecursively(
                to: glass
            )
        }

        anchors.audioEmitter.components.set(SpatialAudioComponent())
        let portalModelCount = bindPortalComponentRecursively(
            to: anchors.portalPlane
        )

        await reloadPortalWorld(
            atmosphere: atmosphere,
            placement: placement
        )

        print(
            """
            [TuringDoorPortal] portal bound
              portalPlane: TuringStoryDoorPortalPlane
              material: PortalMaterial
              target: TuringStoryDoorPortalWorldRoot
              occlusionEnabled: true
              portalModelComponentsUpdated: \(portalModelCount)
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
        placement: TuringStoryDoorBundlePlacement
    ) async {
        let provider = TuringStoryDoorPortalContentProvider(
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
            if let anchors {
                installPortalSlabCloneIfPresent(anchors: anchors)
            }
        } catch {
            print(
                """
                [TuringDoorPortal] ERROR portal world reload failed
                  atmosphere: \(atmosphere.rawValue)
                  error: \(error.localizedDescription)
                """
            )
        }
    }

    private func prunePortalSlabFromPassthroughIfPresent(
        in bundleRoot: Entity
    ) {
        guard let portalSlab = bundleRoot.turingDoorFindEntity(
            named: "TuringStoryDoorPortalSlab_Root"
        ) else {
            print(
                """
                [TuringDoorPortal] portal slab missing
                  entity: TuringStoryDoorPortalSlab_Root
                  action: passthrough_prune_skipped
                  required: false
                """
            )
            return
        }

        portalSlab.isEnabled = false

        print(
            """
            [TuringDoorPortal] portal slab pruned from passthrough render
              entity: TuringStoryDoorPortalSlab_Root
              action: source_entity_disabled
              passthroughPreserved: frame_and_panel
              portalCloneExpected: true
            """
        )
    }

    private func installPortalSlabCloneIfPresent(
        anchors: Anchors
    ) {
        guard let sourceSlab = anchors.portalSlab else {
            print(
                """
                [TuringDoorPortal] portal slab clone skipped
                  source: nil
                  entity: TuringStoryDoorPortalSlab_Root
                """
            )
            return
        }

        let cloneName = "TuringStoryDoorPortalSlab_Root_PortalClone"
        portalWorldRoot.findEntity(named: cloneName)?.removeFromParent()

        let clone = sourceSlab.clone(recursive: true)
        clone.name = cloneName
        setEnabledRecursively(
            clone,
            isEnabled: true
        )
        portalWorldRoot.addChild(clone)
        clone.setTransformMatrix(
            sourceSlab.transformMatrix(relativeTo: portalWorldRoot),
            relativeTo: portalWorldRoot
        )

        print(
            """
            [TuringDoorPortal] portal slab cloned into portal world
              source: TuringStoryDoorPortalSlab_Root
              clone: \(cloneName)
              sourcePassthroughEnabled: \(sourceSlab.isEnabled)
              parent: TuringStoryDoorPortalWorldRoot
              transformBasis: source_relative_to_portalWorldRoot
            """
        )
    }

    private func setEnabledRecursively(
        _ entity: Entity,
        isEnabled: Bool
    ) {
        entity.isEnabled = isEnabled

        for child in entity.children {
            setEnabledRecursively(
                child,
                isEnabled: isEnabled
            )
        }
    }

    private func installAnimationController(
        anchors: Anchors
    ) {
        animationController = TuringStoryDoorAnimationController(
            hingePivot: anchors.hingePivot,
            audioEmitter: anchors.audioEmitter,
            openYawDegrees: config.defaultOpenYawDegrees,
            openDuration: config.openDurationSeconds,
            closeDuration: config.closeDurationSeconds
        )
    }

    private func choosePlacement(
        wallManager: WallPlaneManager,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> TuringStoryDoorBundlePlacement? {
        let width = config.defaultWidthMeters
        let height = config.defaultHeightMeters
        let visualHeight = loadedVisualHeight
        let walls = wallManager.wallCandidates.values
            .filter {
                $0.width >= width
            }

        if walls.isEmpty {
            print(
                """
                [TuringDoorBundle] no wall candidates wide enough
                  requiredWidth: \(width)
                  occupancyHeight: \(height)
                  visualHeight: \(visualHeight)
                  scannedWallCount: \(wallManager.wallCandidates.count)
                """
            )
        }

        var best: (placement: TuringStoryDoorBundlePlacement, score: Float)?

        for wall in walls {
            guard let floor = wallManager.bestFloorCandidate(near: wall) else {
                print(
                    """
                    [TuringDoorBundle] candidate rejected
                      wallID: \(wall.id)
                      reason: missing_floor_candidate_for_floor_snap
                    """
                )
                continue
            }
            let desiredWorldY =
                floor.worldY +
                TuringStoryDoorBundleTuning.minBottomClearanceMeters +
                height * 0.5

            let desiredLocalY: Float
            if abs(wall.up.y) > 0.05 {
                desiredLocalY = (desiredWorldY - wall.center.y) / wall.up.y
            } else {
                desiredLocalY = 0
            }

            let maxX = max(
                0,
                wall.width * 0.5 - width * 0.5 -
                    TuringStoryDoorBundleTuning.wallMarginMeters
            )
            let candidateXs: [Float] = [
                0,
                -maxX * 0.55,
                maxX * 0.55,
                -maxX,
                maxX
            ]

            for x in candidateXs {
                let placement = TuringStoryDoorBundlePlacement(
                    wallID: wall.id,
                    localX: x,
                    localY: desiredLocalY,
                    depthOffset: config.defaultDepthOffsetMeters,
                    width: width,
                    height: height,
                    floorWorldY: floor.worldY,
                    worldYawRadians: worldYawRadians(wall: wall)
                )
                let rect = turingDoorWallRect(for: placement)
                let expandedRect = rect.expanded(
                    by: config.occupancyPaddingMeters
                )

                if wall.height < height {
                    print(
                        """
                        [TuringDoorBundle] wall shorter than occupancy height; using floor snap
                          wallID: \(wall.id)
                          wallHeight: \(wall.height)
                          occupancyHeight: \(height)
                          visualHeight: \(visualHeight)
                          floorWorldY: \(floor.worldY)
                        """
                    )
                }

                if occupancyRegistry?.hasHardOverlap(
                    wallID: wall.id,
                    candidate: expandedRect,
                    candidateKind: .storyDoorBundle
                ) == true {
                    print(
                        """
                        [TuringDoorBundle] candidate rejected by wall occupancy
                          wallID: \(wall.id)
                          reason: overlaps_poster_or_portal_or_story_prop
                        """
                    )
                    continue
                }

                let toWall = turingDoorNormalizeSafe(
                    wall.center - playerPosition,
                    fallback: SIMD3<Float>(0, 0, -1)
                )
                let forward = turingDoorNormalizeSafe(
                    SIMD3<Float>(playerForward.x, 0, playerForward.z),
                    fallback: SIMD3<Float>(0, 0, -1)
                )
                let facingScore = max(
                    0,
                    simd_dot(toWall, forward)
                )
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
                let windowDistance = occupancyRegistry?.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.storyWindowBundle]
                ) ?? Float.greatestFiniteMagnitude
                let score =
                    facingScore * 4.0 +
                    wall.stabilityScore * 2.0 +
                    min(1, posterDistance) *
                        TuringStoryDoorBundleTuning.posterAvoidanceWeight +
                    min(1, portalDistance) *
                        TuringStoryDoorBundleTuning.portalAvoidanceWeight +
                    min(1, walkieDistance) *
                        TuringStoryDoorBundleTuning.walkieAvoidanceWeight +
                    min(1, windowDistance) *
                        TuringStoryDoorBundleTuning.windowAvoidanceWeight -
                    abs(x) * 0.20

                if best == nil || score > best!.score {
                    best = (placement, score)
                }
            }
        }

        return best?.placement
    }

    private func worldTransform(
        placement: TuringStoryDoorBundlePlacement,
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

    private func registerOccupancy(
        placement: TuringStoryDoorBundlePlacement
    ) {
        occupancyRegistry?.unregister(id: occupancyID)
        occupancyRegistry?.register(
            id: occupancyID,
            wallID: placement.wallID,
            kind: .storyDoorBundle,
            rect: turingDoorWallRect(for: placement),
            padding: config.occupancyPaddingMeters,
            label: "Turing Story door portal bundle"
        )
    }

    private func logFloorSnapProof(
        placement: TuringStoryDoorBundlePlacement,
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
        let floorWorldY = placement.floorWorldY

        print(
            """
            [TuringDoorBundle] floor snap proof
              rootOriginWorldY: \(rootPosition.y)
              visualBottomWorldY: \(visualBottomWorld.y)
              floorWorldY: \(floorWorldY.map { "\($0)" } ?? "nil")
              originClearanceMeters: \(floorWorldY.map { "\(rootPosition.y - $0)" } ?? "nil")
              bottomClearanceMeters: \(floorWorldY.map { "\(visualBottomWorld.y - $0)" } ?? "nil")
              expectedBottomClearanceMeters: \(TuringStoryDoorBundleTuning.minBottomClearanceMeters)
              floorSnapBasis: authored_origin
              visualMinY: \(loadedVisualMinY)
              visualMaxY: \(loadedVisualMaxY)
              visualCenterY: \(loadedVisualCenterY)
              assetImportScale: \(TuringStoryDoorBundleTuning.assetImportScale)
            """
        )
    }

    private func groundedRootLocalY(
        placement: TuringStoryDoorBundlePlacement,
        wall: WallCandidate
    ) -> Float {
        guard let floorWorldY = placement.floorWorldY,
              abs(wall.up.y) > 0.05 else {
            return placement.localY - loadedVisualCenterY
        }

        let targetBottomWorldY =
            floorWorldY +
            TuringStoryDoorBundleTuning.minBottomClearanceMeters

        return (targetBottomWorldY - wall.center.y) / wall.up.y
    }

    private func worldYawRadians(
        wall: WallCandidate
    ) -> Float {
        let wallForward = turingDoorNormalizeSafe(
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
    func turingDoorFindEntity(
        named targetName: String
    ) -> Entity? {
        if name == targetName {
            return self
        }

        for child in children {
            if let found = child.turingDoorFindEntity(named: targetName) {
                return found
            }
        }

        return nil
    }

    func turingDoorFindEntity(
        containingNormalized token: String
    ) -> Entity? {
        if normalizedDoorEntityName.contains(token) {
            return self
        }

        for child in children {
            if let found = child.turingDoorFindEntity(
                containingNormalized: token
            ) {
                return found
            }
        }

        return nil
    }

    var normalizedDoorEntityName: String {
        name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private extension Data {
    func turingDoorZIPUInt16(
        at offset: Int
    ) -> UInt16 {
        guard offset + 2 <= count else {
            return 0
        }

        return UInt16(self[offset]) |
            (UInt16(self[offset + 1]) << 8)
    }

    func turingDoorZIPUInt32(
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

private func turingDoorNormalizeSafe(
    _ v: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(v)
    guard length > 0.00001 else {
        return fallback
    }

    return v / length
}
