import Foundation
import MLX

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

    public init(instancePool: TuringQwenNativeFreshInstancePool) {
        self.instancePool = instancePool
    }

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

        let instances = try await instancePool.warmedInstancesExactlyRequestedCount()
        let requested = await instancePool.requestedInstanceCount
        let actual = instances.count
        guard requested == 2, actual == 2 else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh2 requires exactly two warmed instances."
            )
        }

        let runStart = Date()
        let renderPhaseState = TuringQwenRenderPhaseState()
        try await renderPhaseState.beginRun(runID: runID)
        let releaseLedger = TuringQwenRenderReleaseLedger()
        let decodeCoordinator = TuringQwenNativeSpeechDecodeCoordinator(
            releaseLedger: releaseLedger,
            renderPhaseState: renderPhaseState
        )
        let decodeToken = try await decodeCoordinator.beginRun(
            runID: runID,
            modelRoot: modelRoot
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
          sharedWeights: false
          dynamicWorkerQueue: true
          openInputQueue: true
          globalRenderBarrier: false
          freshPathUsesLegacyDecodeGate: false
          fallbackUsed: false
        """)
        await metricsCollector.sampleMemory(label: "runStarted")

        do {
            async let lane0: Void = Self.runLane(
                laneIndex: 0,
                instance: instances[0],
                queue: queue,
                runID: runID,
                skipSegmentFailures: skipSegmentFailures,
                renderPhaseState: renderPhaseState,
                releaseLedger: releaseLedger,
                decodeCoordinator: decodeCoordinator,
                decodeToken: decodeToken,
                metricsCollector: metricsCollector,
                onSegmentStarted: onSegmentStarted,
                onSegmentDecoded: onSegmentDecoded,
                onSegmentSkipped: onSegmentSkipped
            )
            async let lane1: Void = Self.runLane(
                laneIndex: 1,
                instance: instances[1],
                queue: queue,
                runID: runID,
                skipSegmentFailures: skipSegmentFailures,
                renderPhaseState: renderPhaseState,
                releaseLedger: releaseLedger,
                decodeCoordinator: decodeCoordinator,
                decodeToken: decodeToken,
                metricsCollector: metricsCollector,
                onSegmentStarted: onSegmentStarted,
                onSegmentDecoded: onSegmentDecoded,
                onSegmentSkipped: onSegmentSkipped
            )
            _ = try await (lane0, lane1)

            await decodeCoordinator.finishRun(decodeToken)
            await releaseLedger.clearRun(runID)
        } catch {
            await queue.cancel(reason: error.localizedDescription)
            await decodeCoordinator.cancelRun(
                decodeToken,
                reason: error.localizedDescription
            )
            await decodeCoordinator.finishRun(decodeToken)
            await releaseLedger.clearRun(runID)
            throw error
        }

        await metricsCollector.sampleMemory(label: "runFinished")
        let metrics = await metricsCollector.snapshot()
        let overlap = await renderPhaseState.snapshot()
        let submittedCount = await queue.submittedCount()
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
            fallbackUsed: false
        )
    }

    private static func runLane(
        laneIndex: Int,
        instance: TuringQwenNativeFreshInstance,
        queue: TuringQwenOpenSegmentQueue,
        runID: String,
        skipSegmentFailures: Bool,
        renderPhaseState: TuringQwenRenderPhaseState,
        releaseLedger: TuringQwenRenderReleaseLedger,
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

            await renderPhaseState.renderStarted(
                runID: runID,
                segmentIndex: request.segmentIndex,
                instanceID: instanceID
            )
            await onSegmentStarted(instanceID, request.segmentIndex)
            await metricsCollector.sampleMemory(
                label: "render.started.\(request.segmentIndex)"
            )

            let rendered: TuringQwenRenderedCodebookSegment
            do {
                rendered = try await instance.renderCodebookAndRelease(
                    request,
                    runID: runID,
                    releaseLedger: releaseLedger
                )
            } catch {
                await renderPhaseState.renderReleased(
                    runID: runID,
                    segmentIndex: request.segmentIndex,
                    instanceID: instanceID
                )
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

            await renderPhaseState.renderReleased(
                runID: runID,
                segmentIndex: request.segmentIndex,
                instanceID: instanceID
            )
            await metricsCollector.sampleMemory(
                label: "render.released.\(request.segmentIndex)"
            )

            do {
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
