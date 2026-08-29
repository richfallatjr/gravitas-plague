import Foundation
import Metal
import RealityKit
import simd

@MainActor
final class MindEyeDynamicOutputSurface:
    MindEyePresentationVisual,
    MindEyeMotionFrameSink,
    MindEyeAuthoredMouthPlaybackSink,
    MindEyeAuthoredMouthControlling,
    MindEyeGeneratedMouthPlaybackSink,
    MindEyeGeneratedMouthControlling,
    MindEyeVisualSuspensionControlling
{
    let descriptor: MindEyeVisualDescriptor
    let lowLevelTexture: LowLevelTexture
    let textureResource: TextureResource

    private let package: MindEyeAssetPackage
    private let resources: MindEyeCompositorMetalResources

    private(set) var isAttached = false
    private(set) var lastCompletedSequence: UInt64?

    private var isReady = false
    private var frameUpdatesPaused = false
    private var suspensionReasons = Set<MindEyeVisualSuspensionReason>()
    private var disposed = false
    private var renderGeneration: UInt64 = 0
    private var pendingFrame: MindEyeCompositeFrameState?
    private var inFlightSequence: UInt64?
    private var drainTask: Task<Void, Never>?
    private var cropClampCount: UInt64 = 0
    private var coalescedFrameCount: UInt64 = 0
    private var loggedFailureCodes = Set<MindEyeFailureCode>()
    private var motionRegistrationToken: UUID?
    private var motionRootSeed: UInt64?
    private var motionTuning: MindEyeKeepAliveTuning?
    private var latestMotionSample: MindEyeMotionRenderSample = .resting
    private var currentMouthSelection = MindEyeMouthSelection(
        pose: .rest,
        variantIndex: 0
    )
    private var currentMaskMode: MindEyeCompositeMaskMode = .artistRGB
    private var nextCompositeSequence: UInt64 = 1
    private var motionFailureLogged = false
    private let mouthVariantCounts: MindEyeMouthVariantCounts
    private var authoredPlaybackToken: UUID?
    private var authoredTrackDescriptor: MindEyeAuthoredFrameTrackDescriptor?
    private var authoredCompactFrameBytes = 0
    private var authoredPoseRunCount = 0
    private var authoredPlaybackFailureLogged = false
    private var latestAuthoredMouthUpdate: MindEyeAuthoredMouthUpdate?
    private var generatedPlaybackToken: UUID?
    private var generatedSegmentIndex: Int?
    private var generatedTrack: MindEyeGeneratedFrameTrack?
    private var latestGeneratedMouthUpdate: MindEyeGeneratedMouthUpdate?
    private var generatedPlaybackFailureLogged = false

    let cardRoot = Entity()
    let viewportRoot = Entity()
    let outputPlane: ModelEntity
    let contentRoot = Entity()
    let backgroundRoot = Entity()
    let characterRoot = Entity()
    let eyesRoot = Entity()
    let mouthRoot = Entity()

    private init(
        descriptor: MindEyeVisualDescriptor,
        package: MindEyeAssetPackage,
        resources: MindEyeCompositorMetalResources,
        lowLevelTexture: LowLevelTexture,
        textureResource: TextureResource,
        outputPlane: ModelEntity
    ) {
        self.descriptor = descriptor
        self.package = package
        self.resources = resources
        self.lowLevelTexture = lowLevelTexture
        self.textureResource = textureResource
        self.outputPlane = outputPlane
        mouthVariantCounts = MindEyeMouthVariantCounts(
            rest: package.mouths.rest.count,
            small: package.mouths.small.count,
            wide: package.mouths.wide.count,
            round: package.mouths.round.count,
            teeth: package.mouths.teeth.count
        )

        cardRoot.name = "MindEyeCardRoot"
        viewportRoot.name = "MindEyeViewportRoot"
        outputPlane.name = "MindEyeOutputPlane"
        contentRoot.name = "MindEyeContentRoot"
        backgroundRoot.name = "MindEyeBackgroundRoot"
        characterRoot.name = "MindEyeCharacterRoot"
        eyesRoot.name = "MindEyeEyesRoot"
        mouthRoot.name = "MindEyeMouthRoot"

        cardRoot.addChild(viewportRoot)
        viewportRoot.addChild(outputPlane)
        viewportRoot.addChild(contentRoot)
        contentRoot.addChild(backgroundRoot)
        contentRoot.addChild(characterRoot)
        characterRoot.addChild(eyesRoot)
        characterRoot.addChild(mouthRoot)
        cardRoot.position = .zero
        cardRoot.scale = .one
        viewportRoot.position = .zero
        outputPlane.position = .zero
        contentRoot.position = .zero
        outputPlane.isEnabled = false
        cardRoot.isEnabled = false
        Self.makeInert(cardRoot)
    }

    static func make(
        package: MindEyeAssetPackage,
        pipeline: MindEyeCompositorPipeline
    ) async throws -> MindEyeDynamicOutputSurface {
        let resources = try await pipeline.resources().get()
        let placement = package.manifest.placement ?? .phaseThreeDefault
        let descriptor = MindEyeVisualDescriptor(
            characterID: package.characterID,
            vignetteID: package.vignetteID,
            placementTuning: placement,
            outputSize: .viewport
        )
        let textureDescriptor = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .bgra8Unorm_srgb,
            width: MindEyePixelSize.viewport.width,
            height: MindEyePixelSize.viewport.height,
            depth: 1,
            mipmapLevelCount: 1,
            arrayLength: 1,
            textureUsage: [.shaderRead, .shaderWrite],
            swizzle: .init(red: .red, green: .green, blue: .blue, alpha: .alpha)
        )
        let lowLevelTexture: LowLevelTexture
        do {
            lowLevelTexture = try LowLevelTexture(descriptor: textureDescriptor)
        } catch {
            throw failure(
                .outputTextureCreationFailed,
                package: package,
                "Output texture creation failed: \(error.localizedDescription)"
            )
        }
        let textureResource: TextureResource
        do {
            textureResource = try await TextureResource(from: lowLevelTexture)
        } catch {
            throw failure(
                .textureResourceCreationFailed,
                package: package,
                "TextureResource bridge creation failed: \(error.localizedDescription)"
            )
        }
        let material: UnlitMaterial
        switch await MindEyePremultipliedMaterialFactory.make(
            textureResource: textureResource
        ) {
        case .failure(let failure): throw failure
        case .success(let value): material = value
        }
        let plane = ModelEntity(
            mesh: .generatePlane(
                width: placement.cardWidthMeters,
                height: placement.cardHeightMeters
            ),
            materials: [material]
        )
        let surface = MindEyeDynamicOutputSurface(
            descriptor: descriptor,
            package: package,
            resources: resources,
            lowLevelTexture: lowLevelTexture,
            textureResource: textureResource,
            outputPlane: plane
        )
        switch await surface.renderInitialFrame(.phaseFourResting(sequence: 0)) {
        case .failure(let failure):
            surface.dispose(reason: "initialCompositeFailed")
            throw failure
        case .success(let receipt):
            surface.isReady = true
            print(
                "[MindEyePresentation] dynamic initial frame complete " +
                    "vignette=\(package.vignetteID) sequence=\(receipt.completedSequence) " +
                    "sourceBytes=\(package.estimatedResidentSourceBytes)"
            )
            return surface
        }
    }

    func renderInitialFrame(
        _ frame: MindEyeCompositeFrameState
    ) async -> Result<MindEyeCompositeFrameReceipt, MindEyeFailure> {
        guard !disposed, lastCompletedSequence == nil, inFlightSequence == nil else {
            return .failure(failure(.dynamicCompositeFailed, "Initial frame is no longer valid."))
        }
        inFlightSequence = frame.sequence
        let result = await MindEyeCompositeEncoder.encodeAndCommit(
            package: package,
            frame: frame,
            surface: self,
            resources: resources,
            awaitCompletion: true
        )
        inFlightSequence = nil
        if case .success(let receipt) = result {
            lastCompletedSequence = receipt.completedSequence
            if receipt.wasCropClamped { cropClampCount &+= 1 }
        }
        return result
    }

    func enqueueFrame(_ frame: MindEyeCompositeFrameState) {
        guard !disposed else { return }
        let known = [lastCompletedSequence, inFlightSequence, pendingFrame?.sequence]
            .compactMap { $0 }
            .max()
        guard known == nil || frame.sequence > known! else { return }
        if pendingFrame != nil { coalescedFrameCount &+= 1 }
        pendingFrame = frame
        guard !frameUpdatesPaused, inFlightSequence == nil, drainTask == nil else {
            return
        }
        startDrainTask()
    }

    func setFrameUpdatesPaused(_ paused: Bool, reason: String) {
        setVisualSuspension(
            .audioPaused,
            active: paused,
            resampleAt: paused ? nil : ContinuousClock.now,
            diagnosticReason: reason
        )
    }

    func setVisualSuspension(
        _ reason: MindEyeVisualSuspensionReason,
        active: Bool,
        resampleAt instant: ContinuousClock.Instant?,
        diagnosticReason: String
    ) {
        guard !disposed else { return }
        let wasSuspended = !suspensionReasons.isEmpty
        if active {
            suspensionReasons.insert(reason)
        } else {
            suspensionReasons.remove(reason)
        }
        let isSuspended = !suspensionReasons.isEmpty
        let presentationSuspended =
            suspensionReasons.contains(.applicationInactive) ||
            suspensionReasons.contains(.lifecycleTransition)
        frameUpdatesPaused = isSuspended
        if var component = contentRoot.components[MindEyeMotionComponent.self] {
            component.isPaused = isSuspended
            contentRoot.components[MindEyeMotionComponent.self] = component
        }
        if var component = contentRoot.components[MindEyeAuthoredFramePlaybackComponent.self] {
            component.isPaused = isSuspended
            contentRoot.components[MindEyeAuthoredFramePlaybackComponent.self] = component
        }
        if var component = contentRoot.components[MindEyeGeneratedFramePlaybackComponent.self] {
            component.isPaused = isSuspended
            contentRoot.components[MindEyeGeneratedFramePlaybackComponent.self] = component
        }
        if reason != .audioPaused {
            if let token = authoredPlaybackToken {
                _ = MindEyeAuthoredFramePlaybackRegistry.shared.setPresentationSuspended(
                    token: token,
                    suspended: presentationSuspended,
                    resampleAt: presentationSuspended ? nil : instant
                )
            }
            if let token = generatedPlaybackToken {
                _ = MindEyeGeneratedFramePlaybackRegistry.shared.setPresentationSuspended(
                    token: token,
                    suspended: presentationSuspended,
                    resampleAt: presentationSuspended ? nil : instant
                )
            }
        }
        if motionRegistrationToken != nil {
            if isSuspended {
                MindEyeMotionDiagnostics.pause(vignetteID: descriptor.vignetteID)
            } else {
                MindEyeMotionDiagnostics.resume(vignetteID: descriptor.vignetteID)
            }
        }
        print(
            "[MindEyeLifecycle] visual suspension active=\(isSuspended) " +
                "changedReason=\(reason.rawValue) " +
                "reasons=\(suspensionReasons.map(\.rawValue).sorted()) " +
                "diagnostic=\(diagnosticReason)"
        )
        if wasSuspended && !isSuspended,
           pendingFrame != nil,
           inFlightSequence == nil,
           drainTask == nil {
            startDrainTask()
        }
    }

    func startKeepAlive(
        context: MindEyeKeepAliveContext
    ) -> Result<Void, MindEyeFailure> {
        guard !disposed, isReady else {
            return .failure(failure(
                .motionSurfaceUnavailable,
                "Mind's Eye visual is not ready for keep-alive motion."
            ))
        }

        stopKeepAlive(reason: "replaceKeepAlive")

        let tuning: MindEyeKeepAliveTuning
        switch MindEyeKeepAliveTuningResolver.resolve(package: package) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let value):
            tuning = value
        }

        let token = MindEyeMotionFrameRegistry.shared.register(self)
        motionRegistrationToken = token
        motionRootSeed = context.resolvedRootSeed
        motionTuning = tuning
        latestMotionSample = .resting
        motionFailureLogged = false
        let lastKnownSequence = [
            lastCompletedSequence,
            inFlightSequence,
            pendingFrame?.sequence
        ].compactMap { $0 }.max() ?? 0
        nextCompositeSequence = lastKnownSequence &+ 1

        contentRoot.components[MindEyeMotionComponent.self] =
            MindEyeMotionComponent(
                registrationToken: token,
                rootSeed: context.resolvedRootSeed,
                tuning: tuning
            )

        print(
            "[MindEyeMotion] keep-alive started " +
                "speaker=\(descriptor.characterID.rawValue) " +
                "vignette=\(descriptor.vignetteID) " +
                "seed=\(context.resolvedRootSeed)"
        )
        MindEyeMotionDiagnostics.start(
            vignetteID: descriptor.vignetteID,
            seed: context.resolvedRootSeed
        )
        return .success(())
    }

    func stopKeepAlive(reason: String) {
        contentRoot.components.remove(MindEyeMotionComponent.self)
        guard let token = motionRegistrationToken else {
            motionTuning = nil
            motionRootSeed = nil
            return
        }
        let finalSample = latestMotionSample
        MindEyeMotionFrameRegistry.shared.unregister(token: token, reason: reason)
        motionRegistrationToken = nil
        motionTuning = nil
        motionRootSeed = nil
        MindEyeMotionDiagnostics.stop(
            vignetteID: descriptor.vignetteID,
            reason: reason,
            blinkCount: finalSample.blinkCount,
            gripCorrectionCount: finalSample.gripCorrectionCount
        )
        print(
            "[MindEyeMotion] keep-alive stopped " +
                "vignette=\(descriptor.vignetteID) reason=\(reason)"
        )
    }

    func releaseResourceSnapshot() -> MindEyeVisualResourceSnapshot {
        let generatedBytes = generatedTrack.map {
            $0.frameCount + $0.poseRuns.count * MemoryLayout<TuringGeneratedMouthPoseRun>.stride
        } ?? 0
        let outputBytes = UInt64(MindEyePixelSize.viewport.width) *
            UInt64(MindEyePixelSize.viewport.height) * 4
        return MindEyeVisualResourceSnapshot(
            outputTextureCount: disposed ? 0 : 1,
            outputTextureAllocatedBytes: disposed ? 0 : outputBytes,
            activeCardCount: isAttached ? 1 : 0,
            orphanCardCount: !isAttached && cardRoot.parent != nil ? 1 : 0,
            compositorInFlightCount: inFlightSequence == nil ? 0 : 1,
            compositorPendingFrameCount: pendingFrame == nil ? 0 : 1,
            cropClampCount: cropClampCount,
            coalescedFrameCount: coalescedFrameCount,
            authoredCompactFrameBytes: authoredCompactFrameBytes,
            generatedCompactFrameBytes: generatedBytes
        )
    }

    func attach(
        to target: MindEyePlacementTarget,
        placement: MindEyeResolvedPlacement
    ) -> Result<Void, MindEyeFailure> {
        guard isReady, !disposed else {
            return .failure(failure(.dynamicCompositeFailed, "Dynamic surface is not ready."))
        }
        guard target.providerID == placement.providerID,
              target.revision == placement.providerRevision else {
            return .failure(failure(.presentationStale, "Placement target became stale."))
        }
        guard target.parent.parent != nil, target.parent.isEnabled else {
            return .failure(failure(.placementUnavailable, "Presentation parent is unavailable."))
        }
        guard MindEyeFiniteVector.validates(placement.localPosition) else {
            return .failure(failure(.placementInvalid, "Placement is nonfinite."))
        }
        cardRoot.removeFromParent()
        target.parent.addChild(cardRoot)
        cardRoot.transform = Transform(
            scale: .one,
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
            translation: placement.localPosition
        )
        outputPlane.isEnabled = true
        cardRoot.isEnabled = true
        isAttached = true
        return .success(())
    }

    func detach(reason: String) {
        stopGeneratedMouthPlayback(reason: reason, resetToRest: false)
        stopAuthoredMouthPlayback(reason: reason, resetToRest: false)
        stopKeepAlive(reason: reason)
        suspensionReasons.removeAll(keepingCapacity: false)
        frameUpdatesPaused = false
        guard isAttached || cardRoot.parent != nil else { return }
        cardRoot.isEnabled = false
        outputPlane.isEnabled = false
        cardRoot.removeFromParent()
        isAttached = false
        print(
            "[MindEyePresentation] dynamic visual detached " +
                "vignette=\(descriptor.vignetteID) reason=\(reason)"
        )
    }

    func dispose(reason: String) {
        guard !disposed else { return }
        stopGeneratedMouthPlayback(reason: reason, resetToRest: false)
        stopAuthoredMouthPlayback(reason: reason, resetToRest: false)
        stopKeepAlive(reason: reason)
        suspensionReasons.removeAll(keepingCapacity: false)
        frameUpdatesPaused = false
        disposed = true
        renderGeneration &+= 1
        drainTask?.cancel()
        drainTask = nil
        pendingFrame = nil
        detach(reason: reason)
        viewportRoot.children.removeAll()
        cardRoot.children.removeAll()
        isReady = false
        print(
            "[MindEyePresentation] dynamic visual disposed " +
                "vignette=\(descriptor.vignetteID) reason=\(reason) " +
                "cropClampCount=\(cropClampCount)"
        )
    }

    func receiveMindEyeMotionSample(_ sample: MindEyeMotionRenderSample) {
        guard !disposed else { return }
        latestMotionSample = sample
        enqueueFrame(MindEyeCompositeFrameState(
            sequence: nextCompositeSequence,
            backgroundTransform: sample.backgroundTransform,
            characterTransform: sample.characterTransform,
            eyeSelection: sample.eyeSelection,
            mouthSelection: currentMouthSelection,
            maskMode: currentMaskMode
        ))
        nextCompositeSequence &+= 1
    }

    func receiveMindEyeMotionFailure(_ failure: MindEyeFailure) {
        guard !motionFailureLogged else { return }
        motionFailureLogged = true
        MindEyeMotionDiagnostics.failure(
            vignetteID: descriptor.vignetteID,
            code: failure.code
        )
        print(
            "[MindEyeMotion] visual degraded to static " +
                "vignette=\(descriptor.vignetteID) " +
                "code=\(failure.code.rawValue) message=\(failure.message)"
        )
        stopKeepAlive(reason: "motionFailure")
    }

    @discardableResult
    func updateCurrentMouthSelection(
        _ selection: MindEyeMouthSelection
    ) -> Result<Void, MindEyeFailure> {
        guard !disposed else {
            return .failure(failure(
                .authoredFramePlaybackUnavailable,
                "Mouth selection cannot update a disposed surface."
            ))
        }
        guard selection != currentMouthSelection else { return .success(()) }
        let frame = MindEyeCompositeFrameState(
            sequence: nextCompositeSequence,
            backgroundTransform: latestMotionSample.backgroundTransform,
            characterTransform: latestMotionSample.characterTransform,
            eyeSelection: latestMotionSample.eyeSelection,
            mouthSelection: selection,
            maskMode: currentMaskMode
        )
        switch MindEyeCompositeLayerResolver.resolve(package: package, frame: frame) {
        case .failure(let failure):
            if loggedFailureCodes.insert(failure.code).inserted {
                print(
                    "[MindEyePresentation] mouth selection rejected " +
                        "vignette=\(descriptor.vignetteID) " +
                        "code=\(failure.code.rawValue) message=\(failure.message)"
                )
            }
            return .failure(failure)
        case .success:
            currentMouthSelection = selection
            nextCompositeSequence &+= 1
            enqueueFrame(frame)
            return .success(())
        }
    }

    func startAuthoredMouthPlayback(
        context: MindEyeAuthoredMouthPlaybackContext
    ) -> Result<Void, MindEyeFailure> {
        guard !disposed, isReady, isAttached else {
            return .failure(failure(
                .authoredFramePlaybackUnavailable,
                "Authored mouth playback requires an attached ready visual."
            ))
        }
        guard context.track.descriptor.speakerCharacterID == descriptor.characterID else {
            return .failure(failure(
                .authoredFrameSpeakerMismatch,
                "Authored frame track speaker does not match the active portrait."
            ))
        }
        guard mouthVariantCounts.allAreNonempty else {
            return .failure(failure(
                .authoredMouthVariantPlanInvalid,
                "Active portrait does not contain every required mouth family."
            ))
        }

        stopGeneratedMouthPlayback(reason: "replaceWithAuthoredPlayback", resetToRest: false)
        stopAuthoredMouthPlayback(reason: "replaceAuthoredPlayback", resetToRest: false)
        switch MindEyeAuthoredFramePlaybackRegistry.shared.register(
            sink: self,
            context: context,
            counts: mouthVariantCounts
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let registration):
            authoredPlaybackToken = registration.token
            authoredTrackDescriptor = context.track.descriptor
            authoredCompactFrameBytes = context.track.compactPoseByteCount
            authoredPoseRunCount = context.track.poseRuns.count
            authoredPlaybackFailureLogged = false
            latestAuthoredMouthUpdate = registration.initialUpdate
            contentRoot.components[MindEyeAuthoredFramePlaybackComponent.self] =
                MindEyeAuthoredFramePlaybackComponent(
                    registrationToken: registration.token,
                    isPaused: context.clock.isPaused
                )
            if let initial = registration.initialUpdate {
                receiveMindEyeAuthoredMouthUpdate(initial)
            }
            print(
                "[MindEyeAuthored] playback started prID=\(context.track.descriptor.prID) " +
                    "frames=\(context.track.descriptor.frameCount) runs=\(context.track.poseRuns.count)"
            )
            return .success(())
        }
    }

    func receiveMindEyeAuthoredMouthUpdate(_ update: MindEyeAuthoredMouthUpdate) {
        guard authoredTrackDescriptor?.prID == update.prID else { return }
        switch updateCurrentMouthSelection(update.selection) {
        case .success: latestAuthoredMouthUpdate = update
        case .failure(let failure): receiveMindEyeAuthoredMouthFailure(failure)
        }
    }

    func receiveMindEyeAuthoredMouthFailure(_ failure: MindEyeFailure) {
        guard !authoredPlaybackFailureLogged else { return }
        authoredPlaybackFailureLogged = true
        print(
            "[MindEyeAuthored] degraded to rest vignette=\(descriptor.vignetteID) " +
                "code=\(failure.code.rawValue) message=\(failure.message)"
        )
        stopAuthoredMouthPlayback(reason: "authoredPlaybackFailure", resetToRest: true)
    }

    func updateAuthoredMouthClock(
        _ clock: TuringPauseAwarePlaybackClock,
        paused: Bool,
        instant: ContinuousClock.Instant?,
        reason: String
    ) {
        guard let token = authoredPlaybackToken else { return }
        if var component = contentRoot.components[MindEyeAuthoredFramePlaybackComponent.self] {
            component.isPaused = !suspensionReasons.isEmpty
            contentRoot.components[MindEyeAuthoredFramePlaybackComponent.self] = component
        }
        _ = MindEyeAuthoredFramePlaybackRegistry.shared.updateClock(
            token: token,
            clock: clock,
            isPaused: paused,
            sampleAt: paused ? nil : instant
        )
        print(
            "[MindEyeAuthored] clock \(paused ? "paused" : "resumed") " +
                "prID=\(authoredTrackDescriptor?.prID ?? "none") reason=\(reason)"
        )
    }

    func stopAuthoredMouthPlayback(reason: String, resetToRest: Bool) {
        contentRoot.components.remove(MindEyeAuthoredFramePlaybackComponent.self)
        if let token = authoredPlaybackToken {
            MindEyeAuthoredFramePlaybackRegistry.shared.unregister(token: token, reason: reason)
        }
        authoredPlaybackToken = nil
        authoredTrackDescriptor = nil
        authoredCompactFrameBytes = 0
        authoredPoseRunCount = 0
        latestAuthoredMouthUpdate = nil
        authoredPlaybackFailureLogged = false
        if resetToRest {
            _ = updateCurrentMouthSelection(.init(pose: .rest, variantIndex: 0))
        }
    }

    func authoredPlaybackSnapshot() -> MindEyeAuthoredPlaybackSnapshot {
        MindEyeAuthoredPlaybackSnapshot(
            isInstalled: authoredPlaybackToken != nil,
            isPaused: contentRoot.components[MindEyeAuthoredFramePlaybackComponent.self]?.isPaused ?? false,
            prID: authoredTrackDescriptor?.prID,
            manifestSHA256: authoredTrackDescriptor?.manifestSHA256,
            trackFrameIndex: latestAuthoredMouthUpdate?.trackFrameIndex,
            poseRunIndex: latestAuthoredMouthUpdate?.poseRunIndex,
            pose: latestAuthoredMouthUpdate?.selection.pose,
            variantIndex: latestAuthoredMouthUpdate?.selection.variantIndex,
            isPastEnd: latestAuthoredMouthUpdate?.isPastEnd ?? false,
            compactFrameBytes: authoredCompactFrameBytes,
            poseRunCount: authoredPoseRunCount
        )
    }

    func startGeneratedMouthPlayback(
        context: MindEyeGeneratedMouthPlaybackContext
    ) -> Result<Void, MindEyeFailure> {
        guard !disposed, isReady, isAttached else {
            return .failure(failure(
                .generatedMouthPlaybackUnavailable,
                "Generated mouth playback requires an attached ready visual."
            ))
        }
        guard mouthVariantCounts.allAreNonempty else {
            return .failure(failure(
                .generatedMouthVariantPlanInvalid,
                "Active portrait does not contain every required mouth family."
            ))
        }
        stopAuthoredMouthPlayback(reason: "replaceWithGeneratedPlayback", resetToRest: false)
        stopGeneratedMouthPlayback(reason: "replaceGeneratedPlayback", resetToRest: false)
        switch MindEyeGeneratedFramePlaybackRegistry.shared.register(
            sink: self,
            context: context,
            counts: mouthVariantCounts
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let registration):
            generatedPlaybackToken = registration.token
            generatedSegmentIndex = context.segmentIndex
            generatedTrack = context.track
            latestGeneratedMouthUpdate = registration.initialUpdate
            generatedPlaybackFailureLogged = false
            contentRoot.components[MindEyeGeneratedFramePlaybackComponent.self] =
                MindEyeGeneratedFramePlaybackComponent(
                    registrationToken: registration.token,
                    isPaused: context.clock.isPaused
                )
            if let initial = registration.initialUpdate {
                receiveMindEyeGeneratedMouthUpdate(initial)
            }
            print(
                "[MindEyeGenerated] playback started segment=\(context.segmentIndex) " +
                    "frames=\(context.track.frameCount) runs=\(context.track.poseRuns.count)"
            )
            return .success(())
        }
    }

    func receiveMindEyeGeneratedMouthUpdate(_ update: MindEyeGeneratedMouthUpdate) {
        guard generatedSegmentIndex == update.segmentIndex else { return }
        switch updateCurrentMouthSelection(update.selection) {
        case .success: latestGeneratedMouthUpdate = update
        case .failure(let failure): receiveMindEyeGeneratedMouthFailure(failure)
        }
    }

    func receiveMindEyeGeneratedMouthFailure(_ failure: MindEyeFailure) {
        guard !generatedPlaybackFailureLogged else { return }
        generatedPlaybackFailureLogged = true
        print(
            "[MindEyeGenerated] degraded to rest vignette=\(descriptor.vignetteID) " +
                "code=\(failure.code.rawValue) message=\(failure.message) audioContinues=true"
        )
        stopGeneratedMouthPlayback(reason: "generatedPlaybackFailure", resetToRest: true)
    }

    func updateGeneratedMouthClock(
        _ clock: TuringPauseAwarePlaybackClock,
        paused: Bool,
        instant: ContinuousClock.Instant?,
        reason: String
    ) {
        guard let token = generatedPlaybackToken else { return }
        if var component = contentRoot.components[MindEyeGeneratedFramePlaybackComponent.self] {
            component.isPaused = !suspensionReasons.isEmpty
            contentRoot.components[MindEyeGeneratedFramePlaybackComponent.self] = component
        }
        _ = MindEyeGeneratedFramePlaybackRegistry.shared.updateClock(
            token: token,
            clock: clock,
            isPaused: paused,
            sampleAt: paused ? nil : instant
        )
        print(
            "[MindEyeGenerated] clock \(paused ? "paused" : "resumed") " +
                "segment=\(generatedSegmentIndex.map(String.init) ?? "none") reason=\(reason)"
        )
    }

    func stopGeneratedMouthPlayback(reason: String, resetToRest: Bool) {
        contentRoot.components.remove(MindEyeGeneratedFramePlaybackComponent.self)
        if let token = generatedPlaybackToken {
            MindEyeGeneratedFramePlaybackRegistry.shared.unregister(token: token, reason: reason)
        }
        generatedPlaybackToken = nil
        generatedSegmentIndex = nil
        generatedTrack = nil
        latestGeneratedMouthUpdate = nil
        generatedPlaybackFailureLogged = false
        if resetToRest {
            _ = updateCurrentMouthSelection(.init(pose: .rest, variantIndex: 0))
        }
    }

    func generatedPlaybackSnapshot() -> MindEyeGeneratedPlaybackSnapshot {
        MindEyeGeneratedPlaybackSnapshot(
            isInstalled: generatedPlaybackToken != nil,
            isPaused: contentRoot.components[MindEyeGeneratedFramePlaybackComponent.self]?.isPaused ?? false,
            segmentIndex: generatedSegmentIndex,
            sampleRate: generatedTrack?.sampleRate,
            sampleCount: generatedTrack?.sampleCount,
            frameCount: generatedTrack?.frameCount,
            poseRunCount: generatedTrack?.poseRuns.count,
            frameIndex: latestGeneratedMouthUpdate?.frameIndex,
            runIndex: latestGeneratedMouthUpdate?.runIndex,
            pose: latestGeneratedMouthUpdate?.selection.pose,
            variantIndex: latestGeneratedMouthUpdate?.selection.variantIndex,
            isPastEnd: latestGeneratedMouthUpdate?.isPastEnd ?? false
        )
    }

    func motionSnapshot() -> MindEyeMotionSnapshot {
        let component = contentRoot.components[MindEyeMotionComponent.self]
        return MindEyeMotionSnapshot(
            isInstalled: component != nil,
            isPaused: component?.isPaused ?? frameUpdatesPaused,
            rootSeed: motionRootSeed,
            simulationTimeSeconds: latestMotionSample.simulationTimeSeconds,
            motionUpdateIndex: latestMotionSample.motionUpdateIndex,
            backgroundTransform: latestMotionSample.backgroundTransform,
            characterTransform: latestMotionSample.characterTransform,
            eyeSelection: latestMotionSample.eyeSelection,
            blinkCount: latestMotionSample.blinkCount,
            gripCorrectionCount: latestMotionSample.gripCorrectionCount,
            compositorClampCount: cropClampCount,
            compositorCoalescedCount: coalescedFrameCount
        )
    }

    private func startDrainTask() {
        let generation = renderGeneration
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainFrames(generation: generation)
        }
    }

    private func drainFrames(generation: UInt64) async {
        defer {
            drainTask = nil
            if !disposed,
               !frameUpdatesPaused,
               inFlightSequence == nil,
               pendingFrame != nil {
                startDrainTask()
            }
        }
        while !disposed, renderGeneration == generation, !frameUpdatesPaused {
            guard inFlightSequence == nil, let frame = pendingFrame else { return }
            pendingFrame = nil
            inFlightSequence = frame.sequence
            let result = await MindEyeCompositeEncoder.encodeAndCommit(
                package: package,
                frame: frame,
                surface: self,
                resources: resources,
                awaitCompletion: true
            )
            guard !disposed, renderGeneration == generation else { return }
            inFlightSequence = nil
            switch result {
            case .success(let receipt):
                if lastCompletedSequence == nil ||
                    receipt.completedSequence > lastCompletedSequence! {
                    lastCompletedSequence = receipt.completedSequence
                }
                if receipt.wasCropClamped { cropClampCount &+= 1 }
            case .failure(let failure):
                if loggedFailureCodes.insert(failure.code).inserted {
                    print(
                        "[MindEyePresentation] frame update failed " +
                            "vignette=\(descriptor.vignetteID) " +
                            "code=\(failure.code.rawValue) message=\(failure.message)"
                    )
                }
            }
        }
    }

    private func failure(
        _ code: MindEyeFailureCode,
        _ message: String
    ) -> MindEyeFailure {
        Self.failure(code, package: package, message)
    }

    private static func failure(
        _ code: MindEyeFailureCode,
        package: MindEyeAssetPackage,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: code,
            characterID: package.characterID,
            vignetteID: package.vignetteID,
            resourcePath: nil,
            message: message
        )
    }

    private static func makeInert(_ entity: Entity) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)
        for child in entity.children { makeInert(child) }
    }
}

@MainActor
final class MindEyeDynamicVisualFactory: MindEyePresentationVisualBuilding {
    private let pipeline: MindEyeCompositorPipeline

    init(pipeline: MindEyeCompositorPipeline) {
        self.pipeline = pipeline
    }

    func build(
        package: MindEyeAssetPackage
    ) async -> Result<any MindEyePresentationVisual, MindEyeFailure> {
        do {
            return .success(
                try await MindEyeDynamicOutputSurface.make(
                    package: package,
                    pipeline: pipeline
                )
            )
        } catch let failure as MindEyeFailure {
            return .failure(failure)
        } catch {
            return .failure(MindEyeFailure(
                code: .dynamicCompositeFailed,
                characterID: package.characterID,
                vignetteID: package.vignetteID,
                resourcePath: nil,
                message: error.localizedDescription
            ))
        }
    }
}

@MainActor
final class MindEyeUnavailableDynamicVisualFactory: MindEyePresentationVisualBuilding {
    func build(
        package: MindEyeAssetPackage
    ) async -> Result<any MindEyePresentationVisual, MindEyeFailure> {
        .failure(MindEyeFailure(
            code: .noMetalDevice,
            characterID: package.characterID,
            vignetteID: package.vignetteID,
            resourcePath: nil,
            message: "No Metal device is available for Mind's Eye."
        ))
    }
}
