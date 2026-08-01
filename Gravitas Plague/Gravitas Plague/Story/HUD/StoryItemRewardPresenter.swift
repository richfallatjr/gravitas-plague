import Foundation
import RealityKit
import simd
import UIKit

@MainActor
final class StoryItemRewardPresenter {
    typealias AnchorResolver = @MainActor (String) -> Entity?

    private let hudRoot: Entity
    private let anchorResolver: AnchorResolver
    private var worldItemsByID: [String: Entity] = [:]
    private var hudClone: Entity?
    private var hudPresentationID: UUID?
    private var spinTask: Task<Void, Never>?

    init(hudRoot: Entity, anchorResolver: @escaping AnchorResolver) {
        self.hudRoot = hudRoot
        self.anchorResolver = anchorResolver
    }

    func validateAuthoredReward(_ descriptor: Chapter01AntigenRewardDescriptor) throws {
        guard anchorResolver(descriptor.rollingCartAnchorName) != nil else {
            throw Chapter01RobotError.missingRewardArt([descriptor.rollingCartAnchorName])
        }
    }

    func reconcileWorldPresentation(
        itemID: String,
        inventoryQuantity: Int,
        descriptor: Chapter01AntigenRewardDescriptor
    ) async throws {
        guard inventoryQuantity > 0 else { return }
        if worldItemsByID[itemID] != nil { return }
        guard let anchor = anchorResolver(descriptor.rollingCartAnchorName) else {
            throw Chapter01RobotError.missingRewardArt([descriptor.rollingCartAnchorName])
        }
        let entity = try await makeRewardEntity(descriptor)
        entity.name = "StoryInventory_\(itemID)"
        anchor.addChild(entity)
        if descriptor.modelKind == .proceduralCube,
           let size = descriptor.proceduralCubeSizeMeters {
            let worldScale = anchor.scale(relativeTo: nil)
            let inverseScale = SIMD3<Float>(
                1 / max(abs(worldScale.x), 0.0001),
                1 / max(abs(worldScale.y), 0.0001),
                1 / max(abs(worldScale.z), 0.0001)
            )
            entity.scale = inverseScale
            entity.position.y = size * 0.5 * inverseScale.y
        }
        worldItemsByID[itemID] = entity
    }

    func presentHUDReward(
        itemID: String,
        text: String,
        descriptor: Chapter01AntigenRewardDescriptor
    ) async throws {
        guard text == descriptor.hudText,
              let source = worldItemsByID[itemID] else {
            throw Chapter01RobotError.invalidDefinition("reward presentation has no authoritative item")
        }
        clearHUDPresentation(reason: "replaceRewardPresentation")
        let presentationID = UUID()
        let presentationRoot = Entity()
        presentationRoot.name = "StoryRewardHUD_\(itemID)"
        presentationRoot.position = SIMD3<Float>(0, -0.04, -0.62)

        let clone = source.clone(recursive: true)
        clone.name = "StoryRewardHUDModel_\(itemID)"
        clone.transform = Transform()
        makeInert(clone)
        let bounds = clone.visualBounds(
            recursive: true,
            relativeTo: clone,
            excludeInactive: false
        )
        let largestExtent = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        let scale = largestExtent > 0.0001 ? min(1, 0.18 / largestExtent) : 1
        clone.scale = SIMD3<Float>(repeating: scale)
        clone.position = SIMD3<Float>(
            -bounds.center.x * scale,
            0.08 - bounds.center.y * scale,
            -bounds.center.z * scale
        )

        let label = makeHUDLabel(text)
        presentationRoot.addChild(clone)
        presentationRoot.addChild(label)
        hudRoot.addChild(presentationRoot)
        hudClone = presentationRoot
        hudPresentationID = presentationID
        spinTask = Task { @MainActor [weak self, weak clone] in
            let startedAt = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                guard elapsed < descriptor.hudDurationSeconds else { break }
                clone?.orientation = simd_quatf(
                    angle: Float(elapsed * .pi * 0.8),
                    axis: SIMD3<Float>(0, 1, 0)
                )
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
            guard !Task.isCancelled,
                  self?.hudPresentationID == presentationID else { return }
            self?.clearHUDPresentation(reason: "authoredDurationCompleted")
        }
        print("[StoryRewardHUD] presented itemID=\(itemID) text=\(text)")
    }

    func clear(reason: String) {
        clearHUDPresentation(reason: reason)
        print("[StoryRewardHUD] cleared reason=\(reason)")
    }

    private func makeRewardEntity(
        _ descriptor: Chapter01AntigenRewardDescriptor
    ) async throws -> Entity {
        switch descriptor.modelKind {
        case .resource:
            guard let path = descriptor.modelResourcePath else {
                throw Chapter01RobotError.invalidDefinition("reward model resource path is missing")
            }
            let url = try TuringResourceLoader.resourceURL(resourcePath: path)
            return try await Entity(contentsOf: url)
        case .proceduralCube:
            guard let size = descriptor.proceduralCubeSizeMeters else {
                throw Chapter01RobotError.invalidDefinition("temporary antigen cube size is missing")
            }
            let material = SimpleMaterial(
                color: UIColor.systemGreen,
                roughness: 0.28,
                isMetallic: true
            )
            return ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(repeating: size)),
                materials: [material]
            )
        }
    }

    private func makeHUDLabel(_ text: String) -> ModelEntity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.0005,
            font: .systemFont(ofSize: 30, weight: .semibold),
            containerFrame: CGRect(x: -360, y: -35, width: 720, height: 70),
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        var material = UnlitMaterial()
        material.color = .init(tint: .white)
        material.blending = .transparent(opacity: 1.0)
        let label = ModelEntity(mesh: mesh, materials: [material])
        label.name = "StoryRewardHUDText"
        label.scale = SIMD3<Float>(repeating: 0.00075)
        let bounds = mesh.bounds
        label.position = SIMD3<Float>(
            -bounds.center.x * 0.00075,
            -0.08 - bounds.center.y * 0.00075,
            0
        )
        return label
    }

    private func clearHUDPresentation(reason: String) {
        spinTask?.cancel()
        spinTask = nil
        hudPresentationID = nil
        hudClone?.removeFromParent()
        hudClone = nil
        print("[StoryRewardHUD] presentation removed reason=\(reason)")
    }

    private func makeInert(_ entity: Entity) {
        entity.components.remove(CollisionComponent.self)
        entity.components.remove(InputTargetComponent.self)
        for child in entity.children {
            makeInert(child)
        }
    }
}
