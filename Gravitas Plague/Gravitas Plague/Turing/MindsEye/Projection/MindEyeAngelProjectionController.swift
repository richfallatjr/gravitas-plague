import Foundation
import Metal
import RealityKit

/// Owns the single Angel projection package, output texture, mesh material, and
/// coalesced GPU work for one light-tunnel run. Audio remains authoritative:
/// every visual failure is logged and returns to the imported Angel material.
@MainActor
final class MindEyeAngelProjectionController:
    Chapter03AngelProjectionPoseReceiving
{
    static let profileResourcePath =
        "Turing/MindsEye/Projection/profiles/angel_head_v1.json"

    private let runID: UUID
    private let package: MindEyeProjectionPlatePackage
    private let receiverMask: MindEyeProjectionReceiverMaskTextureSource
    private let textureSource: MindEyeProjectionTextureSource
    private let compositorResources: MindEyeProjectionCompositorResources
    private let materialController: MindEyeProjectionMaterialController
    private let blinkTuning = MindEyeResolvedBlinkTuning(
        ordinaryIntervalSeconds: 2.2...4.8,
        closedReferenceFrames: 4...7,
        doubleBlinkProbability: 0.12,
        doubleBlinkGapSeconds: 0.08...0.18,
        referenceFrameRate: 60
    )
    private var randomStreams: MindEyeMotionRandomStreams
    private var mouthRandom: MindEyeDeterministicRandom
    private var blinkScheduler: MindEyeBlinkScheduler
    private var currentEye: MindEyeEyeSelection
    private var currentMouth = MindEyeMouthSelection(
        pose: .rest,
        variantIndex: 0
    )
    private var lastMouthVariantByPose: [MindEyeMouthPose: Int] = [:]
    private var nextSequence: UInt64 = 1
    private var lastCompletedSequence: UInt64 = 0
    private var pendingFrame: MindEyeCompositeFrameState?
    private var renderTask: Task<Void, Never>?
    private var released = false
    private(set) var failedFrameCount: UInt64 = 0

    private init(
        runID: UUID,
        package: MindEyeProjectionPlatePackage,
        receiverMask: MindEyeProjectionReceiverMaskTextureSource,
        textureSource: MindEyeProjectionTextureSource,
        compositorResources: MindEyeProjectionCompositorResources,
        materialController: MindEyeProjectionMaterialController
    ) {
        self.runID = runID
        self.package = package
        self.receiverMask = receiverMask
        self.textureSource = textureSource
        self.compositorResources = compositorResources
        self.materialController = materialController
        let seedDescriptor = MindEyeMotionSeedDescriptor(
            vignetteID: "angel_head_v1",
            speakerCharacterID: "angel",
            playbackRunID: runID.uuidString.lowercased(),
            flowInstanceID: runID,
            sourceIdentity: package.manifest.profileSHA256
        )
        let seed = MindEyeMotionSeedFactory.rootSeed(for: seedDescriptor)
        var streams = MindEyeMotionRandomStreams(rootSeed: seed)
        let scheduler = MindEyeBlinkScheduler(
            tuning: blinkTuning,
            openVariantCount: package.eyeOpen.count,
            closedVariantCount: package.eyeClosed.count,
            streams: &streams
        )
        randomStreams = streams
        mouthRandom = MindEyeDeterministicRandom(
            seed: MindEyeMotionSeedFactory.substreamSeed(
                root: seed,
                tag: "angel-mouth-variants"
            )
        )
        blinkScheduler = scheduler
        currentEye = scheduler.eyeSelection
    }

    static func prepare(
        runID: UUID,
        subjectRoot: Entity,
        preparationToken: MindEyeProjectionPreparationToken
    ) async throws -> MindEyeAngelProjectionController {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MindEyeProjectionError.rendererUnavailable(
                "the system Metal device is unavailable"
            )
        }
        let locator = try MindEyeResourceLocator.applicationBundle()
        let package = try await MindEyeProjectionPlatePackageLoader(
            device: device
        ).load(
            locator: locator,
            profileResourcePath: profileResourcePath,
            qualificationPolicy: runtimeQualificationPolicy
        )
        try preparationToken.requireCurrent()
        let rawReceiverMask = try await MindEyeProjectionReceiverMaskLoader(
            device: device
        ).load(
            locator: locator,
            descriptor: package.profile.projectionReceiverUVMask
        )
        let receiverMask = try await MindEyeProjectionReceiverMaskTextureSource.make(
            payload: rawReceiverMask,
            device: device
        )
        try preparationToken.requireCurrent()
        let textureSource = try await MindEyeProjectionTextureSource.make()
        let compositorResources = try await MindEyeProjectionCompositorPipeline(
            device: device
        ).resources()
        let materialController = MindEyeProjectionMaterialController()
        let controller = MindEyeAngelProjectionController(
            runID: runID,
            package: package,
            receiverMask: receiverMask,
            textureSource: textureSource,
            compositorResources: compositorResources,
            materialController: materialController
        )

        // The first complete open-eye/rest frame exists before the material can
        // become visible, preventing a white/undefined projection flash.
        try await MindEyeProjectionCompositeEncoder.encodeAndCommit(
            package: package,
            frame: controller.makeFrame(sequence: 0),
            output: textureSource,
            resources: compositorResources
        )
        controller.lastCompletedSequence = 0
        try preparationToken.requireCurrent()
        let preparation = try await MindEyeProjectionMaterialFactory.prepare(
            package: package,
            projectionTexture: textureSource,
            receiverMask: receiverMask,
            subjectRoot: subjectRoot
        )
        try preparationToken.requireCurrent()
        try materialController.commit(preparation)
        guard materialController.appliedMaterialCount ==
                package.target.requiredTargetMaterialCount else {
            materialController.release(reason: "incompleteInstallation")
            throw MindEyeProjectionError.materialApplicationFailed(
                "the exact Angel projection target did not receive its material"
            )
        }

        print(
            "[MindEyeProjection] Angel runtime ready " +
                "runID=\(runID.uuidString) packageID=\(package.manifest.packageID) " +
                "cameraSHA=\(package.manifest.cameraSHA256) " +
                "targetSHA=\(package.manifest.targetSHA256) " +
                "profileSHA=\(package.manifest.profileSHA256) " +
                "pbrContract=\(package.importedPBRContract.contractID) " +
                "receiverMaskSHA=\(receiverMask.metadata.SHA256) " +
                "plateResidentBytes=\(package.estimatedPlateResidentBytes) " +
                "sourceTextureCount=\(package.sourceTextureCount) " +
                "outputTextureCount=2 materialCount=\(materialController.appliedMaterialCount)"
        )
        return controller
    }

    /// Development builds intentionally expose the unqualified replacement
    /// material so it can be judged on Vision Pro. Release/TestFlight builds
    /// remain fail-closed until the captured material-parity resource passes.
    private static var runtimeQualificationPolicy:
        MindEyeProjectionPlatePackageLoader.QualificationPolicy
    {
        #if DEBUG
        print(
            "[MindEyeProjection] DEBUG TEST OVERRIDE: " +
                "material parity qualification is not enforced"
        )
        return .allowUnqualifiedAuthoringRun
        #else
        return .requirePassingResource
        #endif
    }

    func setAngelMouthPose(_ pose: MindEyeMouthPose) {
        guard !released,
              let variants = package.mouths[pose],
              !variants.isEmpty else { return }
        let variant = MindEyeVariantIndexSelector.select(
            count: variants.count,
            avoiding: lastMouthVariantByPose[pose],
            random: &mouthRandom
        ) ?? 0
        lastMouthVariantByPose[pose] = variant
        let selection = MindEyeMouthSelection(
            pose: pose,
            variantIndex: variant
        )
        guard selection != currentMouth else { return }
        currentMouth = selection
        submitLatestFrame()
    }

    func update(deltaTime: TimeInterval) {
        guard !released else { return }
        let before = blinkScheduler.eyeSelection
        blinkScheduler.advance(
            deltaTime: Float(min(0.1, max(0, deltaTime))),
            tuning: blinkTuning,
            openVariantCount: package.eyeOpen.count,
            closedVariantCount: package.eyeClosed.count,
            streams: &randomStreams
        )
        if blinkScheduler.eyeSelection != before {
            currentEye = blinkScheduler.eyeSelection
            submitLatestFrame()
        }
    }

    func release(reason: String) {
        guard !released else { return }
        released = true
        pendingFrame = nil
        renderTask?.cancel()
        renderTask = nil
        materialController.release(reason: reason)
        print(
            "[MindEyeProjection] Angel runtime released " +
                "runID=\(runID.uuidString) reason=\(reason) " +
                "lastCompletedSequence=\(lastCompletedSequence) " +
                "failedFrameCount=\(failedFrameCount)"
        )
    }

    private func makeFrame(sequence: UInt64) -> MindEyeCompositeFrameState {
        MindEyeCompositeFrameState(
            sequence: sequence,
            backgroundTransform: .identity,
            characterTransform: .identity,
            eyeSelection: currentEye,
            mouthSelection: currentMouth,
            maskMode: .artistRGB
        )
    }

    private func submitLatestFrame() {
        let sequence = nextSequence
        nextSequence &+= 1
        pendingFrame = makeFrame(sequence: sequence)
        guard renderTask == nil else { return }
        renderTask = Task { @MainActor [weak self] in
            await self?.drainFrames()
        }
    }

    private func drainFrames() async {
        defer { renderTask = nil }
        while !released, !Task.isCancelled, let frame = pendingFrame {
            pendingFrame = nil
            guard frame.sequence > lastCompletedSequence else { continue }
            do {
                try await MindEyeProjectionCompositeEncoder.encodeAndCommit(
                    package: package,
                    frame: frame,
                    output: textureSource,
                    resources: compositorResources
                )
                guard !released, frame.sequence > lastCompletedSequence else {
                    continue
                }
                lastCompletedSequence = frame.sequence
            } catch is CancellationError {
                return
            } catch {
                failedFrameCount &+= 1
                print(
                    "[MindEyeProjection] frame failed; last good retained " +
                        "runID=\(runID.uuidString) sequence=\(frame.sequence) " +
                        "failureCount=\(failedFrameCount) error=\(error.localizedDescription)"
                )
            }
        }
    }
}

private nonisolated extension MindEyeProjectionPlatePackage {
    var sourceTextureCount: Int {
        1 + eyeOpen.count + eyeClosed.count +
            MindEyeMouthPose.allCases.reduce(0) {
                $0 + (mouths[$1]?.count ?? 0)
            }
    }
}
