import Foundation
import RealityKit
import simd

@MainActor
final class JockRetargetTestController {
    enum RetargetError: LocalizedError {
        case missingCharacterAsset
        case noSkinnedModelEntity
        case rigValidationFailed([String])

        var errorDescription: String? {
            switch self {
            case .missingCharacterAsset:
                return "Missing dad_biped.usdz."
            case .noSkinnedModelEntity:
                return "dad_biped.usdz loaded, but no ModelEntity with jointNames was found."
            case .rigValidationFailed(let missing):
                return "Rig validation failed. Missing joints: \(missing.joined(separator: ", "))"
            }
        }
    }

    let rootEntity = Entity()

    private var characterEntity: Entity?
    private var modelEntity: ModelEntity?

    private var rigDefinition: JockRigDefinition?
    private var skeletonMap: JockSkeletonMap?
    private var dummyClip: JockAnimClip?
    private var adapter: JockSkeletonAdapter?
    private var driver: JockRuntimeDriver?

    private var hasLoaded = false
    private var isVisible = false

    private var rootYawRadians: Float = 0

    var debugStatus: String = "Retarget test not loaded."

    init() {
        rootEntity.name = "Gravitas_JockRetargetTestRoot"
        rootEntity.isEnabled = false
    }

    func loadIfNeeded() async throws {
        guard !hasLoaded else { return }

        guard let url = Bundle.main.url(
            forResource: "dad_biped",
            withExtension: "usdz"
        ) else {
            throw RetargetError.missingCharacterAsset
        }

        let loadedEntity = try await Entity(contentsOf: url)
        loadedEntity.name = "dad_biped_loaded_character"

        guard let skinnedModel = firstSkinnedModelEntity(in: loadedEntity) else {
            throw RetargetError.noSkinnedModelEntity
        }

        let rig = try JockAnimationLibraryLoader.loadRigDefinition()
        let map = try JockAnimationLibraryLoader.loadSkeletonMap()
        let clip = try JockAnimationLibraryLoader.loadDummyClip()

        let adapter = JockSkeletonAdapter(
            rig: rig,
            skeletonMap: map,
            runtimeJointNames: skinnedModel.jointNames
        )

        if !adapter.validationReport.missingCanonicalJoints.isEmpty {
            throw RetargetError.rigValidationFailed(
                adapter.validationReport.missingCanonicalJoints
            )
        }

        let driver = JockRuntimeDriver(
            modelEntity: skinnedModel,
            adapter: adapter,
            clip: clip
        )

        rootEntity.addChild(loadedEntity)

        self.characterEntity = loadedEntity
        self.modelEntity = skinnedModel
        self.rigDefinition = rig
        self.skeletonMap = map
        self.dummyClip = clip
        self.adapter = adapter
        self.driver = driver
        self.hasLoaded = true

        debugStatus = """
        Jock Retarget Test loaded.
        Asset: dad_biped.usdz
        Runtime joints: \(skinnedModel.jointNames.count)
        Matched joints: \(adapter.validationReport.matchedJointCount)
        Clip: \(clip.clipID)
        """

        print("[Gravitas] \(debugStatus)")
    }

    func configureSpawn(
        using spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) {
        let headForward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(spawnPose.headForward.x, 0, spawnPose.headForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let position = SIMD3<Float>(
            spawnPose.headPosition.x + headForward.x * 2.25,
            floorY,
            spawnPose.headPosition.z + headForward.z * 2.25
        )

        let faceUserForward = -headForward

        rootYawRadians = PhaseOneMath.yawRadiansForNegativeZForward(
            worldForward: faceUserForward
        )

        rootEntity.position = position
        rootEntity.orientation = simd_quatf(
            angle: rootYawRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    func show() {
        isVisible = true
        rootEntity.isEnabled = true
    }

    func hide() {
        isVisible = false
        driver?.stop()
        rootEntity.isEnabled = false
    }

    func playDummy(loop: Bool) {
        show()
        driver?.setLoopEnabled(loop)
        driver?.playDummyWithTransition()
    }

    func stopDummy() {
        driver?.stop()
    }

    func resetPose() {
        driver?.resetPoseWithTransition()
    }

    func setLoopEnabled(_ enabled: Bool) {
        driver?.setLoopEnabled(enabled)
    }

    func update(deltaTime: Float) {
        guard isVisible else { return }
        driver?.update(deltaTime: TimeInterval(deltaTime))
    }

    private func firstSkinnedModelEntity(in entity: Entity) -> ModelEntity? {
        if let modelEntity = entity as? ModelEntity,
           !modelEntity.jointNames.isEmpty {
            return modelEntity
        }

        for child in entity.children {
            if let found = firstSkinnedModelEntity(in: child) {
                return found
            }
        }

        return nil
    }
}
