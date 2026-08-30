import Foundation
import MLX

#if GR_TURING_QUALIFICATION
import CryptoKit
#endif

public struct TuringQwenNativeFreshSegmentSkip: Sendable {
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let segmentIndex: Int
    public let errorDescription: String

    public init(
        instanceID: TuringQwenNativeFreshInstanceID,
        segmentIndex: Int,
        errorDescription: String
    ) {
        self.instanceID = instanceID
        self.segmentIndex = segmentIndex
        self.errorDescription = errorDescription
    }
}

public actor TuringQwenNativeFreshInstanceScheduler {
    private let instancePool: TuringQwenNativeFreshInstancePool
    private let admissionPolicy: TuringQwenNativeGPUAdmissionPolicy
    private let commandBufferProfile: TuringQwenNativeCommandBufferProfile
    private let recoveryGeneration: TuringQwenNativeRecoveryGeneration
    #if GR_TURING_QUALIFICATION
    private let qualificationSingleLaneControl: Bool
    #endif

    public init(
        instancePool: TuringQwenNativeFreshInstancePool,
        admissionPolicy: TuringQwenNativeGPUAdmissionPolicy,
        commandBufferProfile: TuringQwenNativeCommandBufferProfile = .deviceDefault,
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial
    ) {
        self.instancePool = instancePool
        self.admissionPolicy = admissionPolicy
        self.commandBufferProfile = commandBufferProfile
        self.recoveryGeneration = recoveryGeneration
        #if GR_TURING_QUALIFICATION
        self.qualificationSingleLaneControl = false
        #endif
    }

    #if GR_TURING_QUALIFICATION
    init(
        qualificationSingleLaneInstancePool instancePool:
            TuringQwenNativeFreshInstancePool,
        admissionPolicy: TuringQwenNativeGPUAdmissionPolicy,
        commandBufferProfile: TuringQwenNativeCommandBufferProfile
    ) {
        self.instancePool = instancePool
        self.admissionPolicy = admissionPolicy
        self.commandBufferProfile = commandBufferProfile
        self.recoveryGeneration = instancePool.recoveryGeneration
        self.qualificationSingleLaneControl = true
    }
    #endif

    public func runSegments(
        _ requests: [TuringQwenNativeBaseCloneSegmentRequest],
        runID: String,
        modelRoot: URL,
        skipSegmentFailures: Bool = false,
        onSegmentStarted: @Sendable @escaping (TuringQwenNativeFreshInstanceID, Int) async -> Void,
        onSegmentDecoded: @Sendable @escaping (TuringQwenDecodedSegment) async throws -> Void,
        onSegmentSkipped: @Sendable @escaping (TuringQwenNativeFreshSegmentSkip) async -> Void = { _ in }
    ) async throws -> TuringQwenNativeFreshInstanceRunReport {
        guard requests.isEmpty == false else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Fresh Qwen run requires at least one segment."
            )
        }

        let queue = TuringQwenOpenSegmentQueue()
        try await queue.append(requests)
        await queue.seal()
        return try await runOpenQueue(
            queue,
            runID: runID,
            modelRoot: modelRoot,
            skipSegmentFailures: skipSegmentFailures,
            onSegmentStarted: onSegmentStarted,
            onSegmentDecoded: onSegmentDecoded,
            onSegmentSkipped: onSegmentSkipped
        )
    }

    public func runOpenQueue(
        _ queue: TuringQwenOpenSegmentQueue,
        runID: String,
        modelRoot: URL,
        skipSegmentFailures: Bool = false,
        onSegmentStarted: @Sendable @escaping (
            TuringQwenNativeFreshInstanceID,
            Int
        ) async -> Void,
        onSegmentDecoded: @Sendable @escaping (
            TuringQwenDecodedSegment
        ) async throws -> Void,
        onSegmentSkipped: @Sendable @escaping (
            TuringQwenNativeFreshSegmentSkip
        ) async -> Void = { _ in }
    ) async throws -> TuringQwenNativeFreshInstanceRunReport {

        try await TuringQwenNativeMetalCircuitBreaker.shared.requireHealthy()

        let instances = try await instancePool.warmedInstancesExactlyRequestedCount()
        let requested = await instancePool.requestedInstanceCount
        let actual = instances.count
        #if GR_TURING_QUALIFICATION
        if qualificationSingleLaneControl {
            let mode = instancePool.residencyMode
            guard mode == .singleLaneSharedControl,
                  requested == 1,
                  actual == 1 else {
                throw TuringQwenNativeError.invalidConfig(
                    "Qualification single-lane scheduler requires one warmed shared-control instance."
                )
            }
        } else {
            guard requested == 2, actual == 2 else {
                throw TuringQwenNativeError.invalidConfig(
                    "Fresh2 requires exactly two warmed instances."
                )
            }
        }
        #else
        guard requested == 2, actual == 2 else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh2 requires exactly two warmed instances."
            )
        }
        #endif
        let residencyOwnership = try await instancePool.residencyOwnershipReport()

        let runStart = Date()
        let commandBufferCapture = TuringQwenNativeCommandBufferRunCapture()
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "mlx.commandBuffer.run.begin",
            runID: runID,
            details: [
                "profile": commandBufferProfile.rawValue,
                "admissionMode": admissionPolicy.mode.rawValue
            ]
        )
        let renderPhaseState = TuringQwenRenderPhaseState()
        try await renderPhaseState.beginRun(runID: runID)
        let releaseLedger = TuringQwenRenderReleaseLedger()
        let residencySnapshots = try await instancePool
            .residencySnapshotsForDiagnostics()
        let gpuAdmission = TuringQwenNativeGPUAdmissionController(
            policy: admissionPolicy
        )
        await gpuAdmission.beginRun(runID: runID)
        let decodeCoordinator = TuringQwenNativeSpeechDecodeCoordinator(
            releaseLedger: releaseLedger,
            renderPhaseState: renderPhaseState,
            gpuAdmission: gpuAdmission,
            residencySnapshots: residencySnapshots
        )
        let decodeToken = try await decodeCoordinator.beginRun(
            runID: runID,
            modelRoot: modelRoot,
            generation: recoveryGeneration
        )
        let metricsCollector = TuringQwenNativeFreshInstanceMetricsCollector(
            instanceIDs: instances.map(\.id)
        )

        print("""
        [TuringQwenFresh2] run started
          runID: \(runID)
          requestedInstanceCount: \(requested)
          actualInstanceCount: \(actual)
          skipSegmentFailures: \(skipSegmentFailures)
          residencyMode: \(residencyOwnership.mode.rawValue)
          uniqueResidentResources: \(residencyOwnership.uniqueResidentResourceCount)
          uniqueWeightStores: \(residencyOwnership.uniqueWeightStoreCount)
          uniqueCloneConditionings: \(residencyOwnership.uniqueCloneConditioningCount)
          sharedWeights: \(residencyOwnership.mode == .sharedImmutableFresh2)
          dynamicWorkerQueue: true
          openInputQueue: true
          globalRenderBarrier: false
          gpuAdmissionMode: \(admissionPolicy.mode.rawValue)
          maximumConcurrentGenerationLeases: \(admissionPolicy.maximumConcurrentGenerationLeases)
          decoderHasPriority: \(admissionPolicy.decoderHasPriority)
          freshPathUsesLegacyDecodeGate: false
          fallbackUsed: false
        """)
        await metricsCollector.sampleMemory(label: "runStarted")

        let admissionSnapshot: TuringQwenNativeGPUAdmissionSnapshot
        do {
            try await Self.runLaneOperations(
                instances.indices.map { laneIndex in
                    let instance = instances[laneIndex]
                    return {
                        try await Self.runLane(
                            laneIndex: laneIndex,
                            instance: instance,
                            instancePool: self.instancePool,
                            queue: queue,
                            runID: runID,
                            recoveryGeneration: self.recoveryGeneration,
                            skipSegmentFailures: skipSegmentFailures,
                            renderPhaseState: renderPhaseState,
                            releaseLedger: releaseLedger,
                            gpuAdmission: gpuAdmission,
                            decodeCoordinator: decodeCoordinator,
                            decodeToken: decodeToken,
                            metricsCollector: metricsCollector,
                            onSegmentStarted: onSegmentStarted,
                            onSegmentDecoded: onSegmentDecoded,
                            onSegmentSkipped: onSegmentSkipped
                        )
                    }
                }
            )

            #if GR_TURING_QUALIFICATION
            try await instancePool.verifySharedWeightsUnchangedAfterQualificationRun()
            #endif

            await decodeCoordinator.finishRun(decodeToken)
            await releaseLedger.clearRun(runID)
            admissionSnapshot = try await gpuAdmission.finishRun(
                reason: "schedulerFinished"
            )
        } catch {
            await queue.cancel(reason: error.localizedDescription)
            await gpuAdmission.cancelAll(reason: error.localizedDescription)
            await decodeCoordinator.cancelRun(
                decodeToken,
                reason: error.localizedDescription
            )
            await decodeCoordinator.finishRun(decodeToken)
            await releaseLedger.clearRun(runID)
            _ = try? await gpuAdmission.finishRun(
                reason: "schedulerFailed"
            )
            if let metalFailure = error as? TuringQwenNativeMetalFailure {
                await TuringQwenNativeMetalCircuitBreaker.shared.trip(
                    metalFailure,
                    generation: recoveryGeneration
                )
                TuringQwenNativeDiagnostics.recordBreadcrumb(
                    "qwen.metalCircuitBreaker.tripped",
                    runID: runID,
                    details: [
                        "commandBufferID": String(metalFailure.record.record.commandBufferID),
                        "phase": metalFailure.record.record.lastContext.phase ?? "none",
                        "stage": metalFailure.record.record.lastContext.stage ?? "none"
                    ]
                )
                let decoderReceipt = await decodeCoordinator
                    .cancelAndReleaseForRecovery(
                        token: decodeToken,
                        failure: metalFailure
                    )
                let admissionReceipt = await gpuAdmission.cancelForRecovery(
                    generation: recoveryGeneration,
                    failure: metalFailure
                )
                let queueCancelled = await queue
                    .recoveryCancellationIsComplete()
                let releaseLedgerCleared = await releaseLedger
                    .isRunClear(runID)
                let receipt = await instancePool.unloadForRecovery(
                    reason: "mlxMetalFailure",
                    schedulerEvidence: .init(
                        decoderReceipt: decoderReceipt,
                        admissionReceipt: admissionReceipt,
                        queueCancelled: queueCancelled,
                        releaseLedgerCleared: releaseLedgerCleared
                    )
                )
                await TuringQwenNativeMetalCircuitBreaker.shared
                    .beginAfterOwnershipRelease(
                        receipt: receipt,
                        baselineActiveBytes:
                            instancePool.baselineMLXActiveBytes
                    )
            }
            throw error
        }

        await metricsCollector.sampleMemory(label: "runFinished")
        await instancePool.recordResidencyPeakBoundary()
        let residencyMemory = await instancePool.residencyRunMetrics()
        let metrics = await metricsCollector.snapshot()
        let overlap = await renderPhaseState.snapshot()
        let submittedCount = await queue.submittedCount()
        let commandBufferMetrics = commandBufferCapture.finish(
            profile: commandBufferProfile,
            admissionMode: admissionPolicy.mode
        )
        commandBufferMetrics.recordBoundedDiagnostics(runID: runID)
        return TuringQwenNativeFreshInstanceRunReport(
            requestedInstanceCount: requested,
            actualInstanceCount: actual,
            totalSegments: submittedCount,
            wallClockSeconds: Date().timeIntervalSince(runStart),
            aggregateGeneratedAudioSeconds: metrics.totalGeneratedAudioSeconds,
            perInstanceRenderSeconds: metrics.perInstanceRenderSeconds,
            perInstanceGeneratedAudioSeconds: metrics.perInstanceGeneratedAudioSeconds,
            sampledPeakPhysFootprintMB: metrics.sampledPeakPhysFootprintMB,
            sampledPeakResidentSizeMB: metrics.sampledPeakResidentSizeMB,
            peakMLXActiveMemoryMB: metrics.peakMLXActiveMemoryMB,
            peakMLXCacheMemoryMB: metrics.peakMLXCacheMemoryMB,
            peakRenderConcurrency: overlap.peakActiveRenderCount,
            peakDecodeConcurrency: metrics.successfulSegmentCount > 0 ? 1 : 0,
            sameSegmentRenderDecodeOverlapCount: overlap.sameSegmentRenderDecodeOverlapCount,
            crossSegmentRenderDecodeOverlapCount: overlap.crossSegmentRenderDecodeOverlapCount,
            gpuAdmission: admissionSnapshot,
            commandBufferMetrics: commandBufferMetrics,
            residencyOwnership: residencyOwnership,
            residencyMemory: residencyMemory,
            fallbackUsed: false
        )
    }

    static func runLaneOperations(
        _ operations: [@Sendable () async throws -> Void]
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask(operation: operation)
            }

            do {
                while try await group.next() != nil {}
            } catch {
                // Observe either lane's terminal error immediately. Awaiting
                // an async-let tuple in lane order allowed lane 0 to keep
                // generating indefinitely when lane 1 was the first task to
                // surface a global MLX Metal failure.
                group.cancelAll()
                throw error
            }
        }
    }

    private static func runLane(
        laneIndex: Int,
        instance: TuringQwenNativeFreshInstance,
        instancePool: TuringQwenNativeFreshInstancePool,
        queue: TuringQwenOpenSegmentQueue,
        runID: String,
        recoveryGeneration: TuringQwenNativeRecoveryGeneration,
        skipSegmentFailures: Bool,
        renderPhaseState: TuringQwenRenderPhaseState,
        releaseLedger: TuringQwenRenderReleaseLedger,
        gpuAdmission: TuringQwenNativeGPUAdmissionController,
        decodeCoordinator: TuringQwenNativeSpeechDecodeCoordinator,
        decodeToken: TuringQwenNativeSpeechDecodeCoordinator.RunToken,
        metricsCollector: TuringQwenNativeFreshInstanceMetricsCollector,
        onSegmentStarted: @Sendable @escaping (
            TuringQwenNativeFreshInstanceID,
            Int
        ) async -> Void,
        onSegmentDecoded: @Sendable @escaping (
            TuringQwenDecodedSegment
        ) async throws -> Void,
        onSegmentSkipped: @Sendable @escaping (
            TuringQwenNativeFreshSegmentSkip
        ) async -> Void
    ) async throws {
        while Task.isCancelled == false,
              let request = try await queue.next() {
            try Task.checkCancellation()
            let instanceID = instance.id
            print("""
            [TuringFresh2] lane render started
              runID: \(runID)
              laneIndex: \(laneIndex)
              instanceID: \(instanceID.rawValue)
              segmentIndex: \(request.segmentIndex)
            """)

            let rendered: TuringQwenRenderedCodebookSegment
            do {
                rendered = try await renderWithAdmission(
                    instance: instance,
                    request: request,
                    runID: runID,
                    laneIndex: laneIndex,
                    renderPhaseState: renderPhaseState,
                    releaseLedger: releaseLedger,
                    gpuAdmission: gpuAdmission,
                    onRenderStarted: {
                        await instancePool.recordResidencyMemoryBoundary(
                            "lane\(laneIndex).firstRenderStarted"
                        )
                        await onSegmentStarted(
                            instanceID,
                            request.segmentIndex
                        )
                        await metricsCollector.sampleMemory(
                            label: "render.started.\(request.segmentIndex)"
                        )
                    }
                ).withRecoveryGeneration(recoveryGeneration)
            } catch {
                if let metalFailure = error as? TuringQwenNativeMetalFailure {
                    await cancelForMetalFailure(
                        metalFailure,
                        generation: recoveryGeneration,
                        queue: queue,
                        gpuAdmission: gpuAdmission,
                        decodeCoordinator: decodeCoordinator,
                        decodeToken: decodeToken
                    )
                    throw error
                }
                await metricsCollector.sampleMemory(
                    label: "render.failed.\(request.segmentIndex)"
                )
                if skipSegmentFailures || isSkippableEOSBeforeGeneratedAudio(error) {
                    await onSegmentSkipped(
                        TuringQwenNativeFreshSegmentSkip(
                            instanceID: instanceID,
                            segmentIndex: request.segmentIndex,
                            errorDescription: error.localizedDescription
                        )
                    )
                    continue
                }
                throw error
            }
            await metricsCollector.sampleMemory(
                label: "render.released.\(request.segmentIndex)"
            )
            await instancePool.recordResidencyMemoryBoundary(
                "lane\(laneIndex).firstRenderReleased"
            )

            do {
                await instancePool.recordResidencyMemoryBoundary(
                    "decoder.firstStarted"
                )
                print("""
                [TuringFresh2] lane entered decoder
                  runID: \(runID)
                  laneIndex: \(laneIndex)
                  instanceID: \(instanceID.rawValue)
                  segmentIndex: \(request.segmentIndex)
                """)
                let decoded = try await decodeCoordinator.decode(
                    rendered,
                    token: decodeToken
                )
                try request.generationQualityPolicy.validateAfterDecode(
                    voiceID: rendered.voiceID,
                    generatedRowCount: rendered.generatedRowCount,
                    peakAbs: decoded.audio.peakAbs,
                    rms: decoded.audio.rms,
                    durationSeconds: decoded.audio.durationSeconds
                )

                #if GR_TURING_QUALIFICATION
                await recordQualificationFingerprint(
                    rendered: rendered,
                    decoded: decoded
                )
                #endif

                guard decoded.recoveryGeneration == recoveryGeneration,
                      await TuringQwenNativeRecoveryCoordinator.shared
                        .isPublishable(generation: recoveryGeneration) else {
                    throw TuringQwenNativeRecoveryUnavailableError(
                        availability: .recovering
                    )
                }
                // Publication returns after the file-backed clip is queued.
                // It does not wait for playback completion.
                try await onSegmentDecoded(decoded)
                await metricsCollector.record(
                    TuringQwenNativeFreshInstanceSegmentMetrics(
                        instanceID: decoded.instanceID,
                        segmentIndex: decoded.segmentIndex,
                        renderSeconds: rendered.renderMetrics.elapsedSeconds,
                        audioDurationSeconds: decoded.audio.durationSeconds
                    )
                )
                await metricsCollector.sampleMemory(
                    label: "segmentPublished.\(decoded.segmentIndex)"
                )
                print("""
                [TuringSegmentPipeline] audio published
                  runID: \(runID)
                  segmentIndex: \(decoded.segmentIndex)
                  instanceID: \(decoded.instanceID.rawValue)
                  audioDurationSeconds: \(String(format: "%.3f", decoded.audio.durationSeconds))
                """)
                print("""
                [TuringFresh2] lane publication completed
                  runID: \(runID)
                  laneIndex: \(laneIndex)
                  instanceID: \(decoded.instanceID.rawValue)
                  segmentIndex: \(decoded.segmentIndex)
                  nextRequestEligible: true
                """)
            } catch {
                if let metalFailure = error as? TuringQwenNativeMetalFailure {
                    await cancelForMetalFailure(
                        metalFailure,
                        generation: recoveryGeneration,
                        queue: queue,
                        gpuAdmission: gpuAdmission,
                        decodeCoordinator: decodeCoordinator,
                        decodeToken: decodeToken
                    )
                    throw error
                }
                if skipSegmentFailures || isSkippableEOSBeforeGeneratedAudio(error) {
                    await onSegmentSkipped(
                        TuringQwenNativeFreshSegmentSkip(
                            instanceID: instanceID,
                            segmentIndex: request.segmentIndex,
                            errorDescription: error.localizedDescription
                        )
                    )
                    continue
                }
                throw error
            }
        }
    }

    private static func cancelForMetalFailure(
        _ failure: TuringQwenNativeMetalFailure,
        generation: TuringQwenNativeRecoveryGeneration,
        queue: TuringQwenOpenSegmentQueue,
        gpuAdmission: TuringQwenNativeGPUAdmissionController,
        decodeCoordinator: TuringQwenNativeSpeechDecodeCoordinator,
        decodeToken: TuringQwenNativeSpeechDecodeCoordinator.RunToken
    ) async {
        await TuringQwenNativeMetalCircuitBreaker.shared.trip(
            failure,
            generation: generation
        )
        await queue.cancel(reason: "mlxMetalFailure")
        await gpuAdmission.cancelAll(reason: "mlxMetalFailure")
        await decodeCoordinator.cancelRun(
            decodeToken,
            reason: "mlxMetalFailure"
        )
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "mlx.commandBuffer.failed",
            runID: decodeToken.runID,
            instanceID: failure.record.record.lastContext.instanceID,
            segmentIndex: failure.record.record.lastContext.segmentIndex,
            details: [
                "commandBufferID": String(failure.record.record.commandBufferID),
                "gpuSeconds": String(format: "%.9f", failure.record.record.GPUSeconds),
                "kernelSeconds": String(format: "%.9f", failure.record.record.kernelSeconds),
                "phase": failure.record.record.lastContext.phase ?? "none",
                "stage": failure.record.record.lastContext.stage ?? "none"
            ]
        )
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "qwen.run.cancelledForMetalFailure",
            runID: decodeToken.runID,
            segmentIndex: failure.record.record.lastContext.segmentIndex,
            details: [
                "commandBufferID": String(failure.record.record.commandBufferID),
                "phase": failure.record.record.lastContext.phase ?? "none",
                "stage": failure.record.record.lastContext.stage ?? "none"
            ]
        )
    }

    private static func renderWithAdmission(
        instance: TuringQwenNativeFreshInstance,
        request: TuringQwenNativeBaseCloneSegmentRequest,
        runID: String,
        laneIndex: Int,
        renderPhaseState: TuringQwenRenderPhaseState,
        releaseLedger: TuringQwenRenderReleaseLedger,
        gpuAdmission: TuringQwenNativeGPUAdmissionController,
        onRenderStarted: @Sendable @escaping () async -> Void
    ) async throws -> TuringQwenRenderedCodebookSegment {
        let instanceID = instance.id
        let lease = try await gpuAdmission.acquireGeneration(
            work: TuringQwenNativeGPUWorkIdentity(
                runID: runID,
                segmentIndex: request.segmentIndex,
                laneIndex: laneIndex,
                instanceID: instanceID.rawValue,
                decodeID: nil
            )
        )

        await renderPhaseState.renderStarted(
            runID: runID,
            segmentIndex: request.segmentIndex,
            instanceID: instanceID
        )
        await onRenderStarted()

        do {
            let rendered = try await instance.renderCodebookAndRelease(
                request,
                runID: runID,
                laneIndex: laneIndex,
                releaseLedger: releaseLedger
            )
            await renderPhaseState.renderReleased(
                runID: runID,
                segmentIndex: request.segmentIndex,
                instanceID: instanceID
            )
            await gpuAdmission.release(
                lease,
                reason: "renderCompleted"
            )
            return rendered
        } catch {
            await renderPhaseState.renderReleased(
                runID: runID,
                segmentIndex: request.segmentIndex,
                instanceID: instanceID
            )
            await gpuAdmission.release(
                lease,
                reason: "renderFailed"
            )
            throw error
        }
    }

    #if GR_TURING_QUALIFICATION
    private static func recordQualificationFingerprint(
        rendered: TuringQwenRenderedCodebookSegment,
        decoded: TuringQwenDecodedSegment
    ) async {
        let generatedCodes = rendered.generatedCodes
        let samples = decoded.audio.samples
        let hashes = await Task.detached(priority: .utility) {
            let codebookData = generatedCodes.withUnsafeBytes { Data($0) }
            let pcmData = samples.withUnsafeBytes { Data($0) }
            return (
                codebooks: SHA256.hash(data: codebookData).map {
                    String(format: "%02x", $0)
                }.joined(),
                pcm: SHA256.hash(data: pcmData).map {
                    String(format: "%02x", $0)
                }.joined()
            )
        }.value

        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "gpuAdmission.outputFingerprint",
            runID: rendered.runID,
            instanceID: rendered.instanceID.rawValue,
            segmentIndex: rendered.segmentIndex,
            details: [
                "generatedRowCount": String(rendered.generatedRowCount),
                "codebookCount": String(rendered.codebookCount),
                "codebookSHA256": hashes.codebooks,
                "pcmSampleCount": String(decoded.audio.samples.count),
                "sampleRate": String(decoded.audio.sampleRate),
                "pcmSHA256": hashes.pcm,
                "durationSeconds": String(
                    format: "%.9f",
                    decoded.audio.durationSeconds
                ),
                "peak": String(format: "%.9f", decoded.audio.peakAbs),
                "rms": String(format: "%.9f", decoded.audio.rms)
            ]
        )
    }
    #endif

    private static func isSkippableEOSBeforeGeneratedAudio(_ error: Error) -> Bool {
        if case TuringQwenNativeError.invalidConfig(let message) = error {
            return message == "Base clone generated no codec rows before EOS."
        }

        return error.localizedDescription
            .contains("Base clone generated no codec rows before EOS.")
    }
}

actor TuringQwenNativeFreshInstanceWorkQueue {
    private let totalCount: Int
    private var nextRequestIndex = 0
    private var isCancelled = false

    init(totalCount: Int) {
        self.totalCount = totalCount
    }

    func nextIndex() -> Int? {
        guard isCancelled == false, nextRequestIndex < totalCount else {
            return nil
        }
        defer { nextRequestIndex += 1 }
        return nextRequestIndex
    }

    func cancel() {
        isCancelled = true
    }
}

private actor TuringQwenNativeFreshInstanceMetricsCollector {
    private let instanceIDs: [TuringQwenNativeFreshInstanceID]
    private var perInstanceRenderSeconds: [Double]
    private var perInstanceGeneratedAudioSeconds: [Double]
    private var sampledPeakPhysFootprintMB: Double = 0
    private var sampledPeakResidentSizeMB: Double = 0
    private var peakMLXActiveMemoryMB: Double = 0
    private var peakMLXCacheMemoryMB: Double = 0
    private var successfulSegmentCount = 0

    init(instanceIDs: [TuringQwenNativeFreshInstanceID]) {
        self.instanceIDs = instanceIDs
        self.perInstanceRenderSeconds = Array(repeating: 0, count: instanceIDs.count)
        self.perInstanceGeneratedAudioSeconds = Array(repeating: 0, count: instanceIDs.count)
    }

    func record(_ metrics: TuringQwenNativeFreshInstanceSegmentMetrics) {
        guard let index = instanceIDs.firstIndex(of: metrics.instanceID),
              perInstanceRenderSeconds.indices.contains(index),
              perInstanceGeneratedAudioSeconds.indices.contains(index) else {
            return
        }
        perInstanceRenderSeconds[index] += metrics.renderSeconds
        perInstanceGeneratedAudioSeconds[index] += metrics.audioDurationSeconds
        successfulSegmentCount += 1
    }

    func sampleMemory(label: String) {
        let processMemory = TuringQwenNativeProcessMemoryProbe.snapshot()
        let mlxMemory = Self.mlxMemorySnapshotMegabytes()

        sampledPeakPhysFootprintMB = max(sampledPeakPhysFootprintMB, processMemory.physFootprintMB)
        sampledPeakResidentSizeMB = max(sampledPeakResidentSizeMB, processMemory.residentSizeMB)
        peakMLXActiveMemoryMB = max(peakMLXActiveMemoryMB, mlxMemory.active)
        peakMLXCacheMemoryMB = max(peakMLXCacheMemoryMB, mlxMemory.cache)

        print("""
        [TuringQwenFresh2] memory sampled
          label: \(label)
          physFootprintMB: \(String(format: "%.1f", processMemory.physFootprintMB))
          residentSizeMB: \(String(format: "%.1f", processMemory.residentSizeMB))
          mlxActiveMB: \(String(format: "%.1f", mlxMemory.active))
          mlxCacheMB: \(String(format: "%.1f", mlxMemory.cache))
          sampledPeakPhysFootprintMB: \(String(format: "%.1f", sampledPeakPhysFootprintMB))
        """)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            perInstanceRenderSeconds: perInstanceRenderSeconds,
            perInstanceGeneratedAudioSeconds: perInstanceGeneratedAudioSeconds,
            sampledPeakPhysFootprintMB: sampledPeakPhysFootprintMB,
            sampledPeakResidentSizeMB: sampledPeakResidentSizeMB,
            peakMLXActiveMemoryMB: peakMLXActiveMemoryMB,
            peakMLXCacheMemoryMB: peakMLXCacheMemoryMB,
            successfulSegmentCount: successfulSegmentCount
        )
    }

    private static func mlxMemorySnapshotMegabytes() -> (active: Double, cache: Double) {
        let snapshot = Memory.snapshot()
        let divisor = 1024.0 * 1024.0
        return (
            active: Double(snapshot.activeMemory) / divisor,
            cache: Double(snapshot.cacheMemory) / divisor
        )
    }

    struct Snapshot: Sendable {
        let perInstanceRenderSeconds: [Double]
        let perInstanceGeneratedAudioSeconds: [Double]
        let sampledPeakPhysFootprintMB: Double
        let sampledPeakResidentSizeMB: Double
        let peakMLXActiveMemoryMB: Double
        let peakMLXCacheMemoryMB: Double
        let successfulSegmentCount: Int

        var totalGeneratedAudioSeconds: Double {
            perInstanceGeneratedAudioSeconds.reduce(0, +)
        }
    }
}
