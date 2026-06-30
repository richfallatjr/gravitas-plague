import Foundation
import MLX

public struct TuringQwenNativeQuantizedLinear: Sendable {
    public let tensorPrefix: String
    public let backend: QwenNativeWeightBackend
    public let groupSize: Int
    public let bits: Int

    public init(
        tensorPrefix: String,
        backend: QwenNativeWeightBackend = .mlx4bit,
        groupSize: Int = 64,
        bits: Int = 4
    ) {
        self.tensorPrefix = tensorPrefix
        self.backend = backend
        self.groupSize = groupSize
        self.bits = bits
    }

    public func preflightOnly() throws {
        guard backend == .mlx4bit else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Base clone runtime requires mlx4bit weights, got \(backend.rawValue)."
            )
        }
        guard groupSize == 64,
              bits == 4 else {
            throw TuringQwenNativeError.invalidConfig(
                "Base clone runtime requires 4-bit group size 64 quantized weights, got bits=\(bits) groupSize=\(groupSize)."
            )
        }
    }

    public func apply(
        _ input: MLXArray,
        weight: MLXArray,
        scales: MLXArray,
        biases: MLXArray?
    ) -> MLXArray {
        quantizedMatmul(
            input,
            weight,
            scales: scales,
            biases: biases,
            transpose: true,
            groupSize: groupSize,
            bits: bits,
            mode: .affine
        )
    }
}
