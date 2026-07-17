import Foundation
import MLX

public struct TuringQwenNativeFreshInstanceRunReport: Sendable {
    public let requestedInstanceCount: Int
    public let actualInstanceCount: Int
    public let totalSegments: Int
    public let wallClockSeconds: Double
    public let aggregateGeneratedAudioSeconds: Double
    public let aggregateRealTimeFactor: Double
    public let perInstanceRenderSeconds: [Double]
    public let perInstanceGeneratedAudioSeconds: [Double]
    public let sampledPeakPhysFootprintMB: Double
    public let sampledPeakResidentSizeMB: Double
    public let peakMLXActiveMemoryMB: Double
    public let peakMLXCacheMemoryMB: Double
    public let peakRenderConcurrency: Int
    public let peakDecodeConcurrency: Int
    public let sameSegmentRenderDecodeOverlapCount: Int
    public let crossSegmentRenderDecodeOverlapCount: Int
    public let endPhysFootprintMB: Double
    public let endResidentSizeMB: Double
    public let fallbackUsed: Bool

    public init(
        requestedInstanceCount: Int,
        actualInstanceCount: Int,
        totalSegments: Int,
        wallClockSeconds: Double,
        aggregateGeneratedAudioSeconds: Double,
        perInstanceRenderSeconds: [Double],
        perInstanceGeneratedAudioSeconds: [Double],
        sampledPeakPhysFootprintMB: Double,
        sampledPeakResidentSizeMB: Double,
        peakMLXActiveMemoryMB: Double,
        peakMLXCacheMemoryMB: Double,
        peakRenderConcurrency: Int,
        peakDecodeConcurrency: Int,
        sameSegmentRenderDecodeOverlapCount: Int,
        crossSegmentRenderDecodeOverlapCount: Int,
        fallbackUsed: Bool
    ) {
        self.requestedInstanceCount = requestedInstanceCount
        self.actualInstanceCount = actualInstanceCount
        self.totalSegments = totalSegments
        self.wallClockSeconds = wallClockSeconds
        self.aggregateGeneratedAudioSeconds = aggregateGeneratedAudioSeconds
        self.aggregateRealTimeFactor = aggregateGeneratedAudioSeconds > 0
            ? wallClockSeconds / aggregateGeneratedAudioSeconds
            : 0
        self.perInstanceRenderSeconds = perInstanceRenderSeconds
        self.perInstanceGeneratedAudioSeconds = perInstanceGeneratedAudioSeconds
        self.sampledPeakPhysFootprintMB = sampledPeakPhysFootprintMB
        self.sampledPeakResidentSizeMB = sampledPeakResidentSizeMB
        self.peakMLXActiveMemoryMB = peakMLXActiveMemoryMB
        self.peakMLXCacheMemoryMB = peakMLXCacheMemoryMB
        self.peakRenderConcurrency = peakRenderConcurrency
        self.peakDecodeConcurrency = peakDecodeConcurrency
        self.sameSegmentRenderDecodeOverlapCount = sameSegmentRenderDecodeOverlapCount
        self.crossSegmentRenderDecodeOverlapCount = crossSegmentRenderDecodeOverlapCount
        let endMemory = TuringQwenNativeProcessMemoryProbe.snapshot()
        self.endPhysFootprintMB = endMemory.physFootprintMB
        self.endResidentSizeMB = endMemory.residentSizeMB
        self.fallbackUsed = fallbackUsed
    }

    public func log() {
        print("""
        [TuringQwenFresh2] run finished
          totalSegments: \(totalSegments)
          requestedInstanceCount: \(requestedInstanceCount)
          actualInstanceCount: \(actualInstanceCount)
          aggregateGeneratedAudioSeconds: \(String(format: "%.3f", aggregateGeneratedAudioSeconds))
          wallClockSeconds: \(String(format: "%.3f", wallClockSeconds))
          aggregateRealTimeFactor: \(String(format: "%.3f", aggregateRealTimeFactor))
          perInstanceRenderSeconds: \(perInstanceRenderSeconds.map { String(format: "%.3f", $0) })
          perInstanceGeneratedAudioSeconds: \(perInstanceGeneratedAudioSeconds.map { String(format: "%.3f", $0) })
          sampledPeakPhysFootprintMB: \(String(format: "%.1f", sampledPeakPhysFootprintMB))
          sampledPeakResidentSizeMB: \(String(format: "%.1f", sampledPeakResidentSizeMB))
          peakMLXActiveMemoryMB: \(String(format: "%.1f", peakMLXActiveMemoryMB))
          peakMLXCacheMemoryMB: \(String(format: "%.1f", peakMLXCacheMemoryMB))
          peakRenderConcurrency: \(peakRenderConcurrency)
          peakDecodeConcurrency: \(peakDecodeConcurrency)
          sameSegmentRenderDecodeOverlapCount: \(sameSegmentRenderDecodeOverlapCount)
          crossSegmentRenderDecodeOverlapCount: \(crossSegmentRenderDecodeOverlapCount)
          endPhysFootprintMB: \(String(format: "%.1f", endPhysFootprintMB))
          endResidentSizeMB: \(String(format: "%.1f", endResidentSizeMB))
          fallbackUsed: \(fallbackUsed)
        """)
    }
}

public struct TuringQwenNativeFreshInstanceSegmentMetrics: Sendable {
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let segmentIndex: Int
    public let renderSeconds: Double
    public let audioDurationSeconds: Double
}
