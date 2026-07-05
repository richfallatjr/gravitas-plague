import Foundation
import MLX

public struct TuringQwenNativeFreshInstanceMemoryGate: Sendable {
    public let maxMLXActiveMemoryMB: Int
    public let maxMLXCacheMemoryMB: Int

    public init(
        maxMLXActiveMemoryMB: Int = 6_500,
        maxMLXCacheMemoryMB: Int = 1_500
    ) {
        self.maxMLXActiveMemoryMB = maxMLXActiveMemoryMB
        self.maxMLXCacheMemoryMB = maxMLXCacheMemoryMB
    }

    public func evaluateBeforeWarmLoad(
        instanceID: TuringQwenNativeFreshInstanceID
    ) -> TuringQwenNativeFreshInstanceMemoryDecision {
        let snapshot = Memory.snapshot()
        let divisor = 1024.0 * 1024.0
        let activeMB = Double(snapshot.activeMemory) / divisor
        let cacheMB = Double(snapshot.cacheMemory) / divisor
        let allowed = activeMB < Double(maxMLXActiveMemoryMB) &&
            cacheMB < Double(maxMLXCacheMemoryMB)

        return TuringQwenNativeFreshInstanceMemoryDecision(
            instanceID: instanceID,
            allowed: allowed,
            activeMB: activeMB,
            cacheMB: cacheMB,
            maxActiveMB: maxMLXActiveMemoryMB,
            maxCacheMB: maxMLXCacheMemoryMB
        )
    }
}

public struct TuringQwenNativeFreshInstanceMemoryDecision: Sendable {
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let allowed: Bool
    public let activeMB: Double
    public let cacheMB: Double
    public let maxActiveMB: Int
    public let maxCacheMB: Int
}
