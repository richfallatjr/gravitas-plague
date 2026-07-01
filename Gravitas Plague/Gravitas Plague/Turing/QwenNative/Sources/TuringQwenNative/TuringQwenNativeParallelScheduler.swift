import Foundation

public actor TuringQwenNativeParallelScheduler {
    private let lanePool: TuringQwenNativeParallelLanePool

    public init(
        lanePool: TuringQwenNativeParallelLanePool
    ) {
        self.lanePool = lanePool
    }

    public func renderSegments(
        _ requests: [TuringQwenNativeBaseCloneSegmentRequest],
        runID: String,
        onSegmentStarted: @Sendable @escaping (Int, Int) async -> Void,
        onSegmentFinished: @Sendable @escaping (TuringQwenNativeGeneratedAudio) async throws -> Void
    ) async throws -> TuringQwenNativeParallelPerfReport {
        guard requests.isEmpty == false else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Parallel Qwen perf run requires at least one segment."
            )
        }

        let requested = lanePool.laneCountRequested
        let active = await lanePool.laneCountActive
        let runStart = Date()
        let workQueue = TuringQwenNativeParallelWorkQueue(totalCount: requests.count)
        let metricsCollector = TuringQwenNativeParallelMetricsCollector(
            laneCount: active
        )

        print("""
        [TuringQwenParallel] run started
          runID: \(runID)
          laneCountRequested: \(requested)
          laneCountActive: \(active)
          sharedWeights: true
          streamMode: defaultOnly
        """)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for laneID in 0..<active {
                group.addTask {
                    while let requestIndex = await workQueue.nextIndex() {
                        let request = requests[requestIndex]
                        await onSegmentStarted(laneID, request.segmentIndex)
                        let generated = try await self.lanePool.render(
                            request: request,
                            laneID: laneID
                        )
                        await metricsCollector.record(
                            TuringQwenNativeParallelLaneMetrics(
                                laneID: laneID,
                                segmentIndex: request.segmentIndex,
                                renderSeconds: generated.renderSeconds,
                                audioDurationSeconds: generated.audio.durationSeconds
                            )
                        )
                        try await onSegmentFinished(generated)
                    }
                }
            }

            try await group.waitForAll()
        }

        let metrics = await metricsCollector.snapshot()
        let report = TuringQwenNativeParallelPerfReport(
            laneCountRequested: requested,
            laneCountActive: active,
            wallClockRenderSeconds: Date().timeIntervalSince(runStart),
            totalGeneratedAudioSeconds: metrics.totalGeneratedAudioSeconds,
            perLaneRenderSeconds: metrics.perLaneRenderSeconds,
            perLaneGeneratedAudioSeconds: metrics.perLaneGeneratedAudioSeconds,
            maxConcurrentQwenJobs: active,
            memoryGuardDowngraded: active < requested
        )
        return report
    }
}

private actor TuringQwenNativeParallelWorkQueue {
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

private actor TuringQwenNativeParallelMetricsCollector {
    private var perLaneRenderSeconds: [Double]
    private var perLaneGeneratedAudioSeconds: [Double]

    init(laneCount: Int) {
        self.perLaneRenderSeconds = Array(repeating: 0, count: laneCount)
        self.perLaneGeneratedAudioSeconds = Array(repeating: 0, count: laneCount)
    }

    func record(_ metrics: TuringQwenNativeParallelLaneMetrics) {
        guard perLaneRenderSeconds.indices.contains(metrics.laneID),
              perLaneGeneratedAudioSeconds.indices.contains(metrics.laneID) else {
            return
        }
        perLaneRenderSeconds[metrics.laneID] += metrics.renderSeconds
        perLaneGeneratedAudioSeconds[metrics.laneID] += metrics.audioDurationSeconds
    }

    func snapshot() -> Snapshot {
        Snapshot(
            perLaneRenderSeconds: perLaneRenderSeconds,
            perLaneGeneratedAudioSeconds: perLaneGeneratedAudioSeconds
        )
    }

    struct Snapshot: Sendable {
        let perLaneRenderSeconds: [Double]
        let perLaneGeneratedAudioSeconds: [Double]

        var totalGeneratedAudioSeconds: Double {
            perLaneGeneratedAudioSeconds.reduce(0, +)
        }
    }
}
