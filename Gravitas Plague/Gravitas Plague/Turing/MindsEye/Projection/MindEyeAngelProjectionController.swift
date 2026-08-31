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
        textureSource: MindEyeProjectionTextureSource,
        compositorResources: MindEyeProjectionCompositorResources,
        materialController: MindEyeProjectionMaterialController
    ) {
        self.runID = runID
        self.package = package
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
        subjectRoot: Entity
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
            profileResourcePath: profileResourcePath
        )
        let textureSource = try await MindEyeProjectionTextureSource.make()
        let compositorResources = try await MindEyeProjectionCompositorPipeline(
            device: device
        ).resources()
        let materialController = MindEyeProjectionMaterialController()
        let controller = MindEyeAngelProjectionController(
            runID: runID,
            package: package,
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
        let report = try await MindEyeProjectionMaterialFactory.install(
            package: package,
            textureSource: textureSource,
            subjectRoot: subjectRoot,
            controller: materialController
        )
        guard report.runtimeMaterialAvailable else {
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
                "residentBytes=\(package.estimatedResidentBytes) " +
                "sourceTextureCount=\(package.sourceTextureCount) " +
                "outputTextureCount=1 materialCount=\(report.appliedMaterialCount)"
        )
        return controller
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
        2 + eyeOpen.count + eyeClosed.count +
            MindEyeMouthPose.allCases.reduce(0) {
                $0 + (mouths[$1]?.count ?? 0)
            }
    }
}
