import Foundation
import MLX

public struct TuringQwenNativePerfReport: Codable, Sendable {
    public let presetID: String
    public let modelID: String
    public let quantization: String
    public let fixtureRowsUsed: Bool
    public let performanceMode: String
    public let generatedRows: Int
    public let generatedSamples: Int
    public let sampleRate: Int
    public let audioDurationSeconds: Double
    public let totalRenderSeconds: Double
    public let initialPromptSeconds: Double
    public let initialTalkerForwardSeconds: Double
    public let talkerOneStepTotalSeconds: Double
    public let codePredictorPrefillTotalSeconds: Double
    public let codePredictorOneStepTotalSeconds: Double
    public let codePredictorTotalSeconds: Double
    public let codePredictorPrefillCount: Int
    public let codePredictorOneStepCount: Int
    public let codePredictorNoCacheForwardCount: Int
    public let codePredictorKVCache: String
    public let tokenSyncTotalSeconds: Double
    public let speechDecodeSeconds: Double
    public let playbackStartDelaySeconds: Double?
    public let averageSecondsPerRow: Double
    public let realTimeFactor: Double
    public let mlxActiveMemoryPeakMB: Double?
    public let mlxCacheMemoryPeakMB: Double?
    public let processFootprintPeakMB: Double?
}

struct TuringQwenNativePerfTrace: Sendable {
    var tokenSyncCount = 0
    var tokenSyncTotalSeconds: Double = 0
    var codePredictorPrefillCount = 0
    var codePredictorOneStepCount = 0
    var codePredictorNoCacheForwardCount = 0
    var codePredictorKVCache = "none"
    var codePredictorPrefillTotalSeconds: Double = 0
    var codePredictorOneStepTotalSeconds: Double = 0

    mutating func recordTokenSync(seconds: Double) {
        tokenSyncCount += 1
        tokenSyncTotalSeconds += seconds
    }

    mutating func recordCodePredictor(
        generatedRows: Int,
        codeGroupsPerRow: Int
    ) {
        codePredictorKVCache = "oneStep"
        codePredictorPrefillCount = generatedRows
        codePredictorOneStepCount = generatedRows * max(0, codeGroupsPerRow - 2)
        codePredictorNoCacheForwardCount = 0
    }

    static func log(_ report: TuringQwenNativePerfReport) {
        print("""
        [TuringQwenNativePerf] generation report
          presetID: \(report.presetID)
          modelID: \(report.modelID)
          quantization: \(report.quantization)
          fixtureRowsUsed: \(report.fixtureRowsUsed)
          performanceMode: \(report.performanceMode)
          generatedRows: \(report.generatedRows)
          generatedSamples: \(report.generatedSamples)
          sampleRate: \(report.sampleRate)
          audioDurationSeconds: \(String(format: "%.3f", report.audioDurationSeconds))
          totalRenderSeconds: \(String(format: "%.3f", report.totalRenderSeconds))
          realTimeFactor: \(String(format: "%.3f", report.realTimeFactor))
          averageSecondsPerRow: \(String(format: "%.3f", report.averageSecondsPerRow))
          initialPromptSeconds: \(String(format: "%.3f", report.initialPromptSeconds))
          initialTalkerForwardSeconds: \(String(format: "%.3f", report.initialTalkerForwardSeconds))
          talkerOneStepTotalSeconds: \(String(format: "%.3f", report.talkerOneStepTotalSeconds))
          codePredictorPrefillTotalSeconds: \(String(format: "%.3f", report.codePredictorPrefillTotalSeconds))
          codePredictorOneStepTotalSeconds: \(String(format: "%.3f", report.codePredictorOneStepTotalSeconds))
          codePredictorTotalSeconds: \(String(format: "%.3f", report.codePredictorTotalSeconds))
          codePredictorPrefillCount: \(report.codePredictorPrefillCount)
          codePredictorOneStepCount: \(report.codePredictorOneStepCount)
          codePredictorNoCacheForwardCount: \(report.codePredictorNoCacheForwardCount)
          codePredictorKVCache: \(report.codePredictorKVCache)
          tokenSyncTotalSeconds: \(String(format: "%.3f", report.tokenSyncTotalSeconds))
          speechDecodeSeconds: \(String(format: "%.3f", report.speechDecodeSeconds))
        """)
    }

    static func memoryPeakMegabytes() -> (active: Double, cache: Double) {
        let snapshot = Memory.snapshot()
        let divisor = 1024.0 * 1024.0
        return (
            active: Double(snapshot.activeMemory) / divisor,
            cache: Double(snapshot.cacheMemory) / divisor
        )
    }
}
