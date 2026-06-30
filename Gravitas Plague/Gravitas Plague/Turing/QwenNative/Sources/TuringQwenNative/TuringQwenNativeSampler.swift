import Foundation
import MLX

struct TuringQwenNativeSampledToken {
    let tokenArray: MLXArray
    let tokenIDForStopCheck: Int?
}

enum TuringQwenNativeSampler {
    static func greedyArgmax(
        logits: MLXArray,
        needHostTokenID: Bool,
        perfTrace: inout TuringQwenNativePerfTrace
    ) throws -> TuringQwenNativeSampledToken {
        let tokenArray = greedyTokenArray(from: logits)
        let tokenID = needHostTokenID ? try tokenArray.item(Int.self) : nil
        if needHostTokenID {
            perfTrace.tokenSyncCount += 1
        }
        return TuringQwenNativeSampledToken(
            tokenArray: tokenArray,
            tokenIDForStopCheck: tokenID
        )
    }

    static func greedyTokenArray(
        from logits: MLXArray
    ) -> MLXArray {
        logits[0, 0].argMax(keepDims: true)
    }

    static func greedyToken(
        from logits: MLXArray
    ) throws -> Int {
        try greedyTokenArray(from: logits).item(Int.self)
    }
}
