import Foundation
import RealityKit
import simd

@MainActor
final class Chapter03AngelPortalEntity {
    private enum PresentationVariant: String {
        case staticPosed
        case animatedFloat
    }

    private enum Layout {
        static let activeVariant: PresentationVariant = .staticPosed
        static let staticResourceName = "angel_posed_01"
        static let animatedResourceName = "angel_biped"
        static let animatedClipID = "angel_float_pose_01"
        static let authoredFacingCorrectionRadians: Float = 0
    }

    let root: Entity

    let visualRoot: Entity
    private let presentationVariant: PresentationVariant
    private let poseDriver: JockRuntimeDriver?
    private let emissionFallbackController:
        Chapter03AngelEmissionFallbackController?
    private let basePosition: SIMD3<Float>
    private var floatMotion: Chapter03AngelFloatMotion
    private(set) var blendShapeController: Chapter03AngelBlendShapeController?

    private init(
        root: Entity,
        visual: Entity,
        presentationVariant: PresentationVariant,
        poseDriver: JockRuntimeDriver?,
        emissionFallbackController: Chapter03AngelEmissionFallbackController?,
        blendShapeController: Chapter03AngelBlendShapeController?,
        floatMotionSeed: UInt64
    ) {
        self.root = root
        visualRoot = visual
        self.presentationVariant = presentationVariant
        self.poseDriver = poseDriver
        self.emissionFallbackController = emissionFallbackController
        self.blendShapeController = blendShapeController
        basePosition = root.position
        floatMotion = Chapter03AngelFloatMotion(seed: floatMotionSeed)
    }

    static func load(
        insideOffsetMeters: Float,
        rootYOffsetMeters: Float
    ) async throws -> Chapter03AngelPortalEntity {
        switch Layout.activeVariant {
        case .staticPosed:
            return try await loadStaticPosed(
                insideOffsetMeters: insideOffsetMeters,
                rootYOffsetMeters: rootYOffsetMeters
            )
        case .animatedFloat:
            return try await loadAnimatedFloat(
                insideOffsetMeters: insideOffsetMeters,
                rootYOffsetMeters: rootYOffsetMeters
            )
        }
    }

    private static func loadStaticPosed(
        insideOffsetMeters: Float,
        rootYOffsetMeters: Float
    ) async throws -> Chapter03AngelPortalEntity {
        guard let assetURL = Bundle.main.url(
            forResource: Layout.staticResourceName,
            withExtension: "usdz"
        ) else {
            throw Chapter03Error.angelResourceMissing(
                "\(Layout.staticResourceName).usdz"
            )
        }

        let visual = try await Entity(contentsOf: assetURL)
        let emissionReport = try Chapter03AngelEmissionApplier.apply(
            to: visual,
            assetName: assetURL.lastPathComponent
        )
        let emissionFallbackController = try
            Chapter03AngelEmissionFallbackController(root: visual)
        visual.name = "Chapter03StaticPosedAngelVisual"
        stripInteraction(from: visual)
        visual.scale = SIMD3<Float>(repeating: 1)
        visual.position = .zero

        let root = makePortalRoot(
            visual: visual,
            insideOffsetMeters: insideOffsetMeters,
            rootYOffsetMeters: rootYOffsetMeters
        )
        let blendShapeController = await makeBlendShapeController(
            visual: visual,
            assetURL: assetURL
        )

        print(
            """
            [Chapter03Angel] static portal pose installed
              asset=\(assetURL.lastPathComponent)
              authoredScale=1
              portalLocalPosition=\(root.position)
              runtimeEmissionIntensity=\(Chapter03AngelEmissionApplier.targetIntensity)
              emissiveMaterialsUpdated=\(emissionReport.emissiveMaterialsUpdated)
              yawDegrees=0
              animatedMachineryRetained=true
              animatedMachineryLoaded=false
              transitionsToPassthrough=false
            """
        )

        return Chapter03AngelPortalEntity(
            root: root,
            visual: visual,
            presentationVariant: .staticPosed,
            poseDriver: nil,
            emissionFallbackController: emissionFallbackController,
            blendShapeController: blendShapeController,
            floatMotionSeed: UInt64.random(in: .min ... .max)
        )
    }

    // Retained as the ready-to-reactivate animated variant. The active static
    // path never calls this method and therefore does not create a rig adapter,
    // runtime driver, or prepared animation clip.
    private static func loadAnimatedFloat(
        insideOffsetMeters: Float,
        rootYOffsetMeters: Float
    ) async throws -> Chapter03AngelPortalEntity {
        guard let assetURL = Bundle.main.url(
            forResource: Layout.animatedResourceName,
            withExtension: "usdz"
        ) else {
            throw Chapter03Error.angelResourceMissing(
                "\(Layout.animatedResourceName).usdz"
            )
        }

        let visual = try await Entity(contentsOf: assetURL)
        visual.name = "Chapter03AnimatedAngelVisual"
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
            $0.clipID == Layout.animatedClipID && $0.approvedForRuntime
        }) else {
            throw Chapter03Error.angelPoseUnavailable(
                "missing approved clip \(Layout.animatedClipID)"
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

        let root = makePortalRoot(
            visual: visual,
            insideOffsetMeters: insideOffsetMeters,
            rootYOffsetMeters: rootYOffsetMeters
        )

        print(
                "[Chapter03Angel] portal pose installed " +
                "asset=\(assetURL.lastPathComponent) " +
                "clip=\(Layout.animatedClipID) " +
                "authoredScale=1 " +
                "portalLocalPosition=\(root.position) " +
                "yawDegrees=0 transitionsToPassthrough=false"
        )

        return Chapter03AngelPortalEntity(
            root: root,
            visual: visual,
            presentationVariant: .animatedFloat,
            poseDriver: poseDriver,
            emissionFallbackController: nil,
            blendShapeController: nil,
            floatMotionSeed: UInt64.random(in: .min ... .max)
        )
    }

    func updateFloatMotion(deltaTime: TimeInterval) {
        let offset = floatMotion.update(deltaTime: deltaTime)
        root.position = basePosition + offset
    }

    func setProjectionReadiness(_ readiness: Chapter03AngelProjectionReadiness) {
        let resolved = Chapter03AngelProjectionReadiness(
            cameraReady: readiness.cameraReady,
            materialReady: readiness.materialReady,
            textureReady: readiness.textureReady,
            maskReady: readiness.maskReady,
            blendShapeReady: readiness.blendShapeReady &&
                blendShapeController != nil
        )
        if resolved.isVisualProjectionReady {
            emissionFallbackController?.projectionMaterialDidInstall(
                reason: "projectionReady"
            )
        } else {
            emissionFallbackController?.restoreFallback(
                reason: "projectionUnavailable"
            )
        }
        blendShapeController?.setProjectionReadiness(resolved)
    }

    func release(reason: String) {
        emissionFallbackController?.restoreFallback(
            reason: "chapter03Angel.\(reason)"
        )
        blendShapeController?.reset(
            immediately: true,
            reason: "chapter03Angel.\(reason)"
        )
        blendShapeController = nil
        let preparedClipCount = poseDriver?.releasePreparedRuntime(
            reason: "chapter03Angel.\(reason)"
        ) ?? 0
        root.removeFromParent()
        print(
            "[Chapter03Angel] portal pose released " +
                "variant=\(presentationVariant.rawValue) " +
                "reason=\(reason) preparedClipCount=\(preparedClipCount)"
        )
    }

    private static func makeBlendShapeController(
        visual: Entity,
        assetURL: URL
    ) async -> Chapter03AngelBlendShapeController? {
        do {
            let descriptorURL = try TuringResourceLoader.resourceURL(
                resourcePath: Chapter03AngelBlendShapeDescriptorStore.resourcePath
            )
            let descriptor = try await Chapter03AngelBlendShapeDescriptorStore()
                .loadProduction(
                    descriptorURL: descriptorURL,
                    assetURL: assetURL
                )
            let offsetPayloadURL = try TuringResourceLoader.resourceURL(
                resourcePath: descriptor.offsetPayloadResourcePath
            )
            let offsetPayload = try await Chapter03AngelBlendShapeDescriptorStore()
                .loadOffsetPayload(
                    descriptor: descriptor,
                    payloadURL: offsetPayloadURL
                )
            let repair = try Chapter03AngelBlendShapeMeshRepair.repairIfNeeded(
                root: visual,
                targetName: descriptor.blendShapeName,
                payload: offsetPayload
            )
            print(
                "[Chapter03AngelBlendShape] mesh import ready " +
                "repairedParts=\(repair.repairedPartCount) " +
                "alreadyValidParts=\(repair.alreadyValidPartCount) " +
                "maximumImportedOffsetBeforeRepair=\(repair.maximumImportedOffset)"
            )
            let bindings = try Chapter03AngelBlendShapeResolver().resolve(
                in: visual,
                targetName: descriptor.blendShapeName
            )
            return try Chapter03AngelBlendShapeController(
                descriptor: descriptor,
                bindings: bindings
            )
        } catch {
            // The owner-authored target may not have been packaged yet. The
            // original weight-zero Angel is the required nonfatal fallback.
            Chapter03AngelBlendShapeDiagnostics.fallbackToBase(error: error)
            return nil
        }
    }

    private static func makePortalRoot(
        visual: Entity,
        insideOffsetMeters: Float,
        rootYOffsetMeters: Float
    ) -> Entity {
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
        return root
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
