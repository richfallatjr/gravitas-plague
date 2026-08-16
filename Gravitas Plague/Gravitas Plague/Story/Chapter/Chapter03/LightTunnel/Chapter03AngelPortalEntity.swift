import Foundation
import RealityKit
import simd

@MainActor
final class Chapter03AngelPortalEntity {
    private enum Layout {
        static let resourceName = "angel_biped"
        static let clipID = "angel_float_pose_01"
        static let authoredFacingCorrectionRadians: Float = .pi
    }

    let root: Entity

    private let visual: Entity
    private let modelEntity: ModelEntity
    private let poseDriver: JockRuntimeDriver

    private init(
        root: Entity,
        visual: Entity,
        modelEntity: ModelEntity,
        poseDriver: JockRuntimeDriver
    ) {
        self.root = root
        self.visual = visual
        self.modelEntity = modelEntity
        self.poseDriver = poseDriver
    }

    static func load(
        insideOffsetMeters: Float,
        rootYOffsetMeters: Float
    ) async throws -> Chapter03AngelPortalEntity {
        guard let assetURL = Bundle.main.url(
            forResource: Layout.resourceName,
            withExtension: "usdz"
        ) else {
            throw Chapter03Error.angelResourceMissing(
                "\(Layout.resourceName).usdz"
            )
        }

        let visual = try await Entity(contentsOf: assetURL)
        visual.name = "Chapter03AngelVisual"
        stripInteraction(from: visual)

        guard let modelEntity = firstSkinnedModelEntity(in: visual) else {
            throw Chapter03Error.angelPoseUnavailable(
                "angel_biped.usdz has no skinned model"
            )
        }

        let rig = try JockAnimationLibraryLoader.loadRigDefinition()
        let skeletonMap = try JockAnimationLibraryLoader.loadSkeletonMap()
        let adapter = JockSkeletonAdapter(
            rig: rig,
            skeletonMap: skeletonMap,
            runtimeJointNames: modelEntity.jointNames
        )
        guard adapter.validationReport.isUsable else {
            throw Chapter03Error.angelPoseUnavailable(
                "angel skeleton is incompatible with the animation library"
            )
        }

        let manifest = try JockAnimationLibraryLoader.loadManifest()
        guard let summary = manifest.clips.first(where: {
            $0.clipID == Layout.clipID && $0.approvedForRuntime
        }) else {
            throw Chapter03Error.angelPoseUnavailable(
                "missing approved clip \(Layout.clipID)"
            )
        }
        let poseClip = try JockAnimationLibraryLoader.loadClip(summary: summary)
        let poseDriver = JockRuntimeDriver(
            modelEntity: modelEntity,
            adapter: adapter,
            characterArchetype: .dad,
            poseApplicationPolicy: .authorAbsoluteLocal
        )
        poseDriver.prewarmClips([poseClip])
        poseDriver.playClip(
            poseClip,
            loop: true,
            transition: false,
            locomotionPolicy: .ignoreClipLocomotion
        )

        // The authored biped USDZ already uses the same real-world scale as the
        // other production character assets. Skinned visualBounds are not a
        // valid scale source and previously inflated this model dramatically.
        visual.scale = SIMD3<Float>(repeating: 1)
        visual.position = .zero

        let root = Entity()
        root.name = "Chapter03PortalAngelRoot"
        root.position = SIMD3<Float>(
            0,
            rootYOffsetMeters,
            -insideOffsetMeters
        )
        root.orientation = simd_quatf(
            angle: Layout.authoredFacingCorrectionRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )
        root.addChild(visual)

        print(
                "[Chapter03Angel] portal pose installed " +
                "asset=\(assetURL.lastPathComponent) " +
                "clip=\(Layout.clipID) " +
                "authoredScale=1 " +
                "portalLocalPosition=\(root.position) " +
                "yawDegrees=180 transitionsToPassthrough=false"
        )

        return Chapter03AngelPortalEntity(
            root: root,
            visual: visual,
            modelEntity: modelEntity,
            poseDriver: poseDriver
        )
    }

    func release(reason: String) {
        let preparedClipCount = poseDriver.releasePreparedRuntime(
            reason: "chapter03Angel.\(reason)"
        )
        root.removeFromParent()
        print(
            "[Chapter03Angel] portal pose released " +
                "reason=\(reason) preparedClipCount=\(preparedClipCount)"
        )
    }

    private static func firstSkinnedModelEntity(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, !model.jointNames.isEmpty {
            return model
        }
        for child in entity.children {
            if let model = firstSkinnedModelEntity(in: child) {
                return model
            }
        }
        return nil
    }

    private static func stripInteraction(from entity: Entity) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)
        for child in entity.children {
            stripInteraction(from: child)
        }
    }
}
