import Foundation
import MLX

enum TuringQwenNativeMemoryControl {
    private static let cacheLimitBytes = 64 * 1024 * 1024

    static func configureForCanary() {
        Memory.cacheLimit = cacheLimitBytes
        Memory.clearCache()
        Memory.peakMemory = 0
        logSnapshot(label: "configured")
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
