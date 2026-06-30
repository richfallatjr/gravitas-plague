import Foundation
import MLX

public struct TuringQwenNativeRealtimeBudget: Codable, Sendable {
    public let preset: String
    public let rowCount: Int
    public let audioDurationSeconds: Double
    public let promptSeconds: Double
    public let talkerSeconds: Double
    public let codePredictorSeconds: Double
    public let decodeSeconds: Double
    public let totalRenderSeconds: Double
    public let realTimeFactor: Double
    public let maxProcessFootprintMB: Double
    public let maxMLXActiveMB: Double
    public let maxMLXCacheMB: Double
}

enum TuringQwenNativeRealtimeBudgetProbe {
    static func realTimeFactor(
        renderSeconds: Double,
        audioDurationSeconds: Double
    ) -> Double {
        guard audioDurationSeconds > 0 else {
            return .infinity
        }

        return renderSeconds / audioDurationSeconds
    }

    static func mlxSnapshotMB() -> (
        active: Double,
        cache: Double,
        peak: Double
    ) {
        let snapshot = Memory.snapshot()
        return (
            active: megabytes(snapshot.activeMemory),
            cache: megabytes(snapshot.cacheMemory),
            peak: megabytes(snapshot.peakMemory)
        )
    }

    private static func megabytes(_ bytes: Int) -> Double {
        Double(bytes) / Double(1024 * 1024)
    }
}
