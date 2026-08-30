import Foundation
import MLX

public struct TuringQwenNativeResidencyMemorySnapshot:
    Sendable,
    Equatable,
    Codable
{
    public let uptimeNanoseconds: UInt64
    public let physicalFootprintMB: Double
    public let residentSizeMB: Double
    public let availableProcessMemoryMB: Double
    public let MLXActiveMB: Double
    public let MLXCacheMB: Double
    public let MLXPeakMB: Double

    public static func capture() -> Self {
        let process = TuringQwenNativeProcessMemoryProbe.snapshot()
        #if os(visionOS)
        let mlx = Memory.snapshot()
        let divisor = 1_048_576.0
        let active = Double(mlx.activeMemory) / divisor
        let cache = Double(mlx.cacheMemory) / divisor
        let peak = Double(mlx.peakMemory) / divisor
        #else
        let active = 0.0
        let cache = 0.0
        let peak = 0.0
        #endif
        return Self(
            uptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000),
            physicalFootprintMB: process.physFootprintMB,
            residentSizeMB: process.residentSizeMB,
            availableProcessMemoryMB: process.availableProcessMemoryMB,
            MLXActiveMB: active,
            MLXCacheMB: cache,
            MLXPeakMB: peak
        )
    }
}

public struct TuringQwenNativeResidentResourceLoadMetrics:
    Sendable,
    Equatable,
    Codable
{
    public let elapsedSeconds: Double
    public let before: TuringQwenNativeResidencyMemorySnapshot
    public let afterConfig: TuringQwenNativeResidencyMemorySnapshot
    public let afterWeightStore: TuringQwenNativeResidencyMemorySnapshot
    public let afterTalkerWeights: TuringQwenNativeResidencyMemorySnapshot
    public let afterCodePredictorWeights: TuringQwenNativeResidencyMemorySnapshot
    public let ready: TuringQwenNativeResidencyMemorySnapshot
}

public struct TuringQwenNativeResidencyMemorySample:
    Sendable,
    Equatable,
    Codable
{
    public let label: String
    public let snapshot: TuringQwenNativeResidencyMemorySnapshot
}

public final class TuringQwenNativeResidencyMetricsRecorder: @unchecked Sendable {
    public let ownerID: UUID
    private let lock = NSLock()
    private var samples: [TuringQwenNativeResidencyMemorySample] = []

    public init(ownerID: UUID) {
        self.ownerID = ownerID
    }

    @discardableResult
    public func record(_ label: String) -> TuringQwenNativeResidencyMemorySnapshot {
        let snapshot = TuringQwenNativeResidencyMemorySnapshot.capture()
        lock.lock()
        if samples.count < 64 {
            samples.append(.init(label: label, snapshot: snapshot))
        }
        lock.unlock()
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.memory.sample",
            ownerID: ownerID,
            details: [
                "label": label,
                "physicalFootprintMB": String(format: "%.1f", snapshot.physicalFootprintMB),
                "mlxActiveMB": String(format: "%.1f", snapshot.MLXActiveMB)
            ]
        )
        return snapshot
    }

    public func boundedSamples() -> [TuringQwenNativeResidencyMemorySample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

public struct TuringQwenNativeResidencyRunMetrics:
    Sendable,
    Equatable,
    Codable
{
    public let ownerLoadSeconds: Double
    public let laneEngineCreationSeconds: [Double]
    public let sessionReadySeconds: Double
    public let firstRenderMemoryByLane:
        [String: TuringQwenNativeResidencyMemorySnapshot]
    public let peakMemory: TuringQwenNativeResidencyMemorySnapshot?
    public let immediatePostOwnerReleaseMemory: TuringQwenNativeResidencyMemorySnapshot?
    public let quiescentPostUnloadMemory: TuringQwenNativeResidencyMemorySnapshot?
    public let boundedSamples: [TuringQwenNativeResidencyMemorySample]

    public init(
        ownerLoadSeconds: Double = 0,
        laneEngineCreationSeconds: [Double] = [],
        sessionReadySeconds: Double = 0,
        firstRenderMemoryByLane: [String: TuringQwenNativeResidencyMemorySnapshot] = [:],
        peakMemory: TuringQwenNativeResidencyMemorySnapshot? = nil,
        immediatePostOwnerReleaseMemory: TuringQwenNativeResidencyMemorySnapshot? = nil,
        quiescentPostUnloadMemory: TuringQwenNativeResidencyMemorySnapshot? = nil,
        boundedSamples: [TuringQwenNativeResidencyMemorySample] = []
    ) {
        self.ownerLoadSeconds = ownerLoadSeconds
        self.laneEngineCreationSeconds = laneEngineCreationSeconds
        self.sessionReadySeconds = sessionReadySeconds
        self.firstRenderMemoryByLane = firstRenderMemoryByLane
        self.peakMemory = peakMemory
        self.immediatePostOwnerReleaseMemory = immediatePostOwnerReleaseMemory
        self.quiescentPostUnloadMemory = quiescentPostUnloadMemory
        self.boundedSamples = boundedSamples
    }
}

public struct TuringQwenNativeResidencyOwnershipReport:
    Sendable,
    Equatable,
    Codable
{
    public let mode: TuringQwenNativeResidencyMode
    public let requestedLaneCount: Int
    public let actualLaneCount: Int
    public let uniqueResidentResourceCount: Int
    public let uniqueWeightStoreCount: Int
    public let uniqueCloneConditioningCount: Int
    public let laneEngineCount: Int
    public let uniqueLaneMutableStateCount: Int
    public let uniqueStaticPromptCacheCount: Int
    public let uniqueTalkerKVCacheOwnerCount: Int
    public let uniqueCodePredictorKVCacheOwnerCount: Int
    public let uniqueSamplerStateOwnerCount: Int
    public let activeLeaseCountAtReady: Int
    public let activeLeaseCountAtFinish: Int
    public let decoderSessionCount: Int
    public let fallbackUsed: Bool
}

public struct TuringQwenNativeSharedResidencyFinishReport:
    Sendable,
    Equatable,
    Codable
{
    public let ownerID: UUID
    public let generation: UInt64
    public let activeLeaseCountAtFinish: Int
    public let reason: String
    public let memoryAfterRelease: TuringQwenNativeResidencyMemorySnapshot
}
