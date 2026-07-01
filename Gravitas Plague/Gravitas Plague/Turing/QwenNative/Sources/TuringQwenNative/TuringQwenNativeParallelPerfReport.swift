import Foundation
import MLX

public struct TuringQwenNativeParallelMemoryPolicy: Sendable {
    public let minAvailableBeforeSecondLaneMB: Int
    public let maxPhysFootprintMB: Int
    public let maxMLXActiveMemoryMB: Int
    public let maxMLXCacheMemoryMB: Int

    public init(
        minAvailableBeforeSecondLaneMB: Int = 2_500,
        maxPhysFootprintMB: Int = 6_500,
        maxMLXActiveMemoryMB: Int = 5_500,
        maxMLXCacheMemoryMB: Int = 1_024
    ) {
        self.minAvailableBeforeSecondLaneMB = minAvailableBeforeSecondLaneMB
        self.maxPhysFootprintMB = maxPhysFootprintMB
        self.maxMLXActiveMemoryMB = maxMLXActiveMemoryMB
        self.maxMLXCacheMemoryMB = maxMLXCacheMemoryMB
    }
}

public struct TuringQwenNativeParallelPerfReport: Sendable {
    public let laneCountRequested: Int
    public let laneCountActive: Int
    public let wallClockRenderSeconds: Double
    public let totalGeneratedAudioSeconds: Double
    public let aggregateRealTimeFactor: Double
    public let perLaneRenderSeconds: [Double]
    public let perLaneGeneratedAudioSeconds: [Double]
    public let maxConcurrentQwenJobs: Int
    public let peakMLXActiveMemoryMB: Double
    public let peakMLXCacheMemoryMB: Double
    public let cacheLimitMB: Int
    public let memoryGuardDowngraded: Bool
    public let orderedPlaybackUnderrunCount: Int
    public let fillerSecondsTotal: Double

    public init(
        laneCountRequested: Int,
        laneCountActive: Int,
        wallClockRenderSeconds: Double,
        totalGeneratedAudioSeconds: Double,
        perLaneRenderSeconds: [Double],
        perLaneGeneratedAudioSeconds: [Double],
        maxConcurrentQwenJobs: Int,
        memoryGuardDowngraded: Bool,
        orderedPlaybackUnderrunCount: Int = 0,
        fillerSecondsTotal: Double = 0
    ) {
        self.laneCountRequested = laneCountRequested
        self.laneCountActive = laneCountActive
        self.wallClockRenderSeconds = wallClockRenderSeconds
        self.totalGeneratedAudioSeconds = totalGeneratedAudioSeconds
        self.aggregateRealTimeFactor = totalGeneratedAudioSeconds > 0
            ? wallClockRenderSeconds / totalGeneratedAudioSeconds
            : 0
        self.perLaneRenderSeconds = perLaneRenderSeconds
        self.perLaneGeneratedAudioSeconds = perLaneGeneratedAudioSeconds
        self.maxConcurrentQwenJobs = maxConcurrentQwenJobs
        let memory = Self.memorySnapshotMegabytes()
        self.peakMLXActiveMemoryMB = memory.active
        self.peakMLXCacheMemoryMB = memory.cache
        self.cacheLimitMB = Memory.cacheLimit / (1024 * 1024)
        self.memoryGuardDowngraded = memoryGuardDowngraded
        self.orderedPlaybackUnderrunCount = orderedPlaybackUnderrunCount
        self.fillerSecondsTotal = fillerSecondsTotal
    }

    public func log(
        singleLaneBaselineRTF: Double? = nil
    ) {
        print("""
        [TuringQwenParallel] run finished
          singleLaneBaselineRTF: \(singleLaneBaselineRTF.map { String(format: "%.3f", $0) } ?? "none")
          laneCountRequested: \(laneCountRequested)
          laneCountActive: \(laneCountActive)
          wallClockRenderSeconds: \(String(format: "%.3f", wallClockRenderSeconds))
          totalGeneratedAudioSeconds: \(String(format: "%.3f", totalGeneratedAudioSeconds))
          aggregateRealTimeFactor: \(String(format: "%.3f", aggregateRealTimeFactor))
          perLaneRenderSeconds: \(perLaneRenderSeconds.map { String(format: "%.3f", $0) })
          perLaneGeneratedAudioSeconds: \(perLaneGeneratedAudioSeconds.map { String(format: "%.3f", $0) })
          maxConcurrentQwenJobs: \(maxConcurrentQwenJobs)
          peakPhysFootprintMB: app_probe
          peakMLXActiveMemoryMB: \(String(format: "%.1f", peakMLXActiveMemoryMB))
          peakMLXCacheMemoryMB: \(String(format: "%.1f", peakMLXCacheMemoryMB))
          cacheLimitMB: \(cacheLimitMB)
          memoryGuardDowngraded: \(memoryGuardDowngraded)
          orderedPlaybackUnderrunCount: \(orderedPlaybackUnderrunCount)
          fillerSecondsTotal: \(String(format: "%.3f", fillerSecondsTotal))
        """)
    }

    static func memorySnapshotMegabytes() -> (active: Double, cache: Double) {
        let snapshot = Memory.snapshot()
        let divisor = 1024.0 * 1024.0
        return (
            active: Double(snapshot.activeMemory) / divisor,
            cache: Double(snapshot.cacheMemory) / divisor
        )
    }
}

public struct TuringQwenNativeParallelLaneMetrics: Sendable {
    public let laneID: Int
    public let segmentIndex: Int
    public let renderSeconds: Double
    public let audioDurationSeconds: Double

    public init(
        laneID: Int,
        segmentIndex: Int,
        renderSeconds: Double,
        audioDurationSeconds: Double
    ) {
        self.laneID = laneID
        self.segmentIndex = segmentIndex
        self.renderSeconds = renderSeconds
        self.audioDurationSeconds = audioDurationSeconds
    }
}
