import Foundation
import MLX

enum TuringQwenNativeMemoryControl {
    private static let diagnosticCacheLimitBytes = 64 * 1024 * 1024

    static func configureForCanary() {
        Memory.cacheLimit = diagnosticCacheLimitBytes
        Memory.clearCache()
        Memory.peakMemory = 0
        logSnapshot(label: "configured")
    }

    static func configureForBaseClone(
        performanceMode: TuringQwenNativePerformanceMode
    ) {
        let cacheLimitBytes = performanceMode.mlxCacheLimitBytes
        if Memory.cacheLimit != cacheLimitBytes {
            Memory.cacheLimit = cacheLimitBytes
        }
        Memory.peakMemory = 0
        print("""
        [TuringQwenNativeMemory] configured base clone runtime
          performanceMode: \(performanceMode.rawValue)
          cacheLimitMB: \(megabytes(Memory.cacheLimit))
          clearCacheAtStart: false
        """)
    }

    static func clearCache(label: String) {
        Memory.clearCache()
        logSnapshot(label: label)
    }

    static func logSnapshot(label: String) {
        let snapshot = Memory.snapshot()
        print("""
        [TuringQwenNativeMemory] snapshot
          label: \(label)
          activeMB: \(megabytes(snapshot.activeMemory))
          cacheMB: \(megabytes(snapshot.cacheMemory))
          peakMB: \(megabytes(snapshot.peakMemory))
          cacheLimitMB: \(megabytes(Memory.cacheLimit))
        """)
    }

    private static func megabytes(_ bytes: Int) -> Int {
        bytes / (1024 * 1024)
    }
}
