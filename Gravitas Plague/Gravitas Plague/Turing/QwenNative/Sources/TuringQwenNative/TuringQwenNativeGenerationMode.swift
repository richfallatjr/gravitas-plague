import Foundation
import MLX

public enum TuringQwenNativeGenerationMode: Sendable, Equatable {
    case fixtureDecode(rows: [[Int]])
    case dynamic(maxNewRows: Int)
}

public struct TuringQwenNativeAudioMetrics: Sendable, Codable {
    public let sampleCount: Int
    public let finiteSampleCount: Int
    public let peakAbs: Float
    public let rms: Float
    public let durationSeconds: Double
}

public struct TuringQwenNativeCodebookSequence: Sendable {
    public let rows: [[Int]]
    public let codebookCount: Int
    public let rowCount: Int
}

struct TuringQwenNativeTalkerGenerationState {
    let kvCache: TuringQwenNativeKVCache
    let position: Int
    let attentionMask: MLXArray
    let generatedCodeGroups: [[Int]]
}

struct TuringQwenNativeGeneratedStepOutput {
    let step: Int
    let firstCodecToken: Int
    let codeGroup: [Int]
    let talkerLastHiddenState: MLXArray
    let stop: Bool
    let state: TuringQwenNativeTalkerGenerationState
}

enum TuringQwenNativeStopReason: String {
    case eos
    case maxTokens
}

enum TuringQwenNativeSampler {
    static func greedyToken(
        from logits: MLXArray
    ) throws -> Int {
        logits.argMax().item(Int.self)
    }
}

enum TuringQwenNativeMemoryProbe {
    static func log(
        stage: String,
        rowIndex: Int? = nil,
        rowCount: Int? = nil
    ) {
        let snapshot = Memory.snapshot()
        let rowIndexText = rowIndex.map { "\n  rowIndex: \($0)" } ?? ""
        let rowCountText = rowCount.map { "\n  rowCount: \($0)" } ?? ""
        print("""
        [TuringQwenNativeMemory] stage=\(stage)\(rowIndexText)\(rowCountText)
          activeMB: \(megabytes(snapshot.activeMemory))
          cacheMB: \(megabytes(snapshot.cacheMemory))
          peakMB: \(megabytes(snapshot.peakMemory))
        """)
    }

    private static func megabytes(_ bytes: Int) -> Int {
        bytes / (1024 * 1024)
    }
}
