import Foundation
import MLX

public actor TuringQwenNativeFreshInstanceScheduler {
    private let instancePool: TuringQwenNativeFreshInstancePool

    public init(
        instancePool: TuringQwenNativeFreshInstancePool
    ) {
        self.instancePool = instancePool
    }

    public func renderSegments(
        _ requests: [TuringQwenNativeBaseCloneSegmentRequest],
        runID: String,
        onSegmentStarted: @Sendable @escaping (TuringQwenNativeFreshInstanceID, Int) async -> Void,
        onSegmentFinished: @Sendable @escaping (TuringQwenNativeFreshSegmentResult) async throws -> Void
    ) async throws -> TuringQwenNativeFreshInstanceRunReport {
        guard requests.isEmpty == false else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Fresh Qwen run requires at least one segment."
            )
        }

        let instances = try await instancePool.warmedInstancesExactlyRequestedCount()
        let requested = await instancePool.requestedInstanceCount
        let actual = instances.count
        let runStart = Date()
        let workQueue = TuringQwenNativeFreshInstanceWorkQueue(totalCount: requests.count)
        let metricsCollector = TuringQwenNativeFreshInstanceMetricsCollector(
            instanceIDs: instances.map(\.id)
        )

        print("""
        [TuringQwenFresh2] run started
          runID: \(runID)
          requestedInstanceCount: \(requested)
          actualInstanceCount: \(actual)
          sharedWeights: false
          fallbackUsed: false
        """)
        await metricsCollector.sampleMemory(label: "runStarted")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for instance in instances {
                group.addTask {
                    while let requestIndex = await workQueue.nextIndex() {
                        let request = requests[requestIndex]
                        let instanceID = instance.id
                        print("""
                        [TuringQwenFresh2] segment scheduled
                          segmentIndex: \(request.segmentIndex)
                          instanceID: \(instanceID.rawValue)
                        """)
                        await metricsCollector.sampleMemory(
                            label: "segmentScheduled.\(request.segmentIndex)"
                        )
                        await onSegmentStarted(instanceID, request.segmentIndex)

                        let renderStart = Date()
                        let audio = try await instance.generate(request)
                        let renderSeconds = Date().timeIntervalSince(renderStart)
                        let result = TuringQwenNativeFreshSegmentResult(
                            instanceID: instanceID,
                            segmentIndex: request.segmentIndex,
                            audio: audio,
                            renderSeconds: renderSeconds
                        )
                        await metricsCollector.record(
                            TuringQwenNativeFreshInstanceSegmentMetrics(
                                instanceID: instanceID,
                                segmentIndex: request.segmentIndex,
                                renderSeconds: renderSeconds,
                                audioDurationSeconds: audio.durationSeconds
                            )
                        )
                        await metricsCollector.sampleMemory(
                            label: "segmentFinished.\(request.segmentIndex)"
                        )
                        print("""
                        [TuringQwenFresh2] segment finished
                          segmentIndex: \(request.segmentIndex)
                          instanceID: \(instanceID.rawValue)
                          renderSeconds: \(String(format: "%.3f", renderSeconds))
                          audioDurationSeconds: \(String(format: "%.3f", audio.durationSeconds))
                          realTimeFactor: \(String(format: "%.3f", audio.durationSeconds > 0 ? renderSeconds / audio.durationSeconds : 0))
                        """)
                        try await onSegmentFinished(result)
                    }
                }
            }

            try await group.waitForAll()
        }

        await metricsCollector.sampleMemory(label: "runFinished")
        let metrics = await metricsCollector.snapshot()
        return TuringQwenNativeFreshInstanceRunReport(
            requestedInstanceCount: requested,
            actualInstanceCount: actual,
            totalSegments: requests.count,
            wallClockSeconds: Date().timeIntervalSince(runStart),
            aggregateGeneratedAudioSeconds: metrics.totalGeneratedAudioSeconds,
            perInstanceRenderSeconds: metrics.perInstanceRenderSeconds,
            perInstanceGeneratedAudioSeconds: metrics.perInstanceGeneratedAudioSeconds,
            sampledPeakPhysFootprintMB: metrics.sampledPeakPhysFootprintMB,
            sampledPeakResidentSizeMB: metrics.sampledPeakResidentSizeMB,
            peakMLXActiveMemoryMB: metrics.peakMLXActiveMemoryMB,
            peakMLXCacheMemoryMB: metrics.peakMLXCacheMemoryMB,
            fallbackUsed: false
        )
    }
}

private actor TuringQwenNativeFreshInstanceWorkQueue {
    private let totalCount: Int
    private var next = 0

    init(totalCount: Int) {
        self.totalCount = totalCount
    }

    func nextIndex() -> Int? {
        guard next < totalCount else {
            return nil
        }
        let index = next
        next += 1
        return index
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
    }

    func sampleMemory(label: String) {
        let processMemory = TuringQwenNativeProcessMemoryProbe.snapshot()
        let mlxMemory = Self.mlxMemorySnapshotMegabytes()

        sampledPeakPhysFootprintMB = max(
            sampledPeakPhysFootprintMB,
            processMemory.physFootprintMB
        )
        sampledPeakResidentSizeMB = max(
            sampledPeakResidentSizeMB,
            processMemory.residentSizeMB
        )
        peakMLXActiveMemoryMB = max(
            peakMLXActiveMemoryMB,
            mlxMemory.active
        )
        peakMLXCacheMemoryMB = max(
            peakMLXCacheMemoryMB,
            mlxMemory.cache
        )

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
            peakMLXCacheMemoryMB: peakMLXCacheMemoryMB
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

        var totalGeneratedAudioSeconds: Double {
            perInstanceGeneratedAudioSeconds.reduce(0, +)
        }
    }
}
