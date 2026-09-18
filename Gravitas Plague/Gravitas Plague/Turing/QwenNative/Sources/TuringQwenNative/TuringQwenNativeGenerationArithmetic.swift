import MLX
import MLXFast

/// C2 is generation-only and opt-in. Decoder arithmetic and sampling are not
/// selected here. Identity branches deliberately preserve the legacy graph.
enum TuringQwenNativeGenerationArithmetic {
    static var isBF16: Bool {
        TuringQwenNativeExecutionPolicy.current.arithmetic == .bf16Candidate
    }

    static func activation(_ value: MLXArray) -> MLXArray {
        isBF16 ? value.asType(.bfloat16) : value
    }

    /// Compute vocabulary heads in FP32, rather than widening rounded logits.
    static func logitInput(_ value: MLXArray) -> MLXArray {
        isBF16 ? value.asType(.float32) : value
    }

    static func rmsNorm(
        _ value: MLXArray, weight: MLXArray, epsilon: Float, forceManual: Bool
    ) -> MLXArray {
        if !isBF16 {
            if !forceManual { return MLXFast.rmsNorm(value, weight: weight, eps: epsilon) }
            let variance = (value * value).mean(axis: -1, keepDims: true)
            return value / sqrt(variance + epsilon) * weight
        }
        if !forceManual {
            // Vendored BF16 RMSNorm rounds the normalized value BEFORE its
            // affine multiply on CPU and Metal. Keep this sensitive operation
            // FP32 through the multiply, then round the stored activation once.
            return MLXFast.rmsNorm(value.asType(.float32),
                                   weight: weight.asType(.float32), eps: epsilon)
                .asType(.bfloat16)
        }
        let wide = value.asType(.float32)
        let variance = (wide * wide).mean(axis: -1, keepDims: true)
        return (wide / sqrt(variance + epsilon) * weight.asType(.float32))
            .asType(.bfloat16)
    }

    static func attentionProbabilities(_ scores: MLXArray, legacyPrecise: Bool) -> MLXArray {
        if !isBF16 { return softmax(scores, axis: -1, precise: legacyPrecise) }
        return softmax(scores.asType(.float32), axis: -1, precise: true).asType(.bfloat16)
    }
}
