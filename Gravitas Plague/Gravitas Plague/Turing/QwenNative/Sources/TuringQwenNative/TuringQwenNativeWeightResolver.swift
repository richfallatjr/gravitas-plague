import Foundation
import MLX

struct TuringQwenNativeWeightResolver: @unchecked Sendable {
    private let store: TuringQwenNativeWeightsStore

    init(store: TuringQwenNativeWeightsStore) {
        self.store = store
    }

    func tensor(_ key: String) throws -> MLXArray {
        try store.require(key)
    }

    func optionalTensor(_ key: String) -> MLXArray? {
        store.optional(key)
    }

    func linear(
        _ key: String,
        groupSize: Int = 64,
        bits: Int = 4
    ) throws -> TuringQwenNativeLinearWeight {
        let weight = try tensor(key)
        if weight.dtype == .uint32 {
            guard let scales = optionalTensor(quantizedCompanionKey(key, suffix: "scales")) else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "Quantized tensor \(key) is missing matching .scales."
                )
            }
            let biases = optionalTensor(quantizedCompanionKey(key, suffix: "biases"))
            return .quantized(
                TuringQwenNativeQuantizedLinearWeight(
                    weight: weight,
                    scales: scales,
                    biases: biases,
                    groupSize: groupSize,
                    bits: bits
                )
            )
        }

        return .dense(weight)
    }

    func rows(
        _ key: String,
        rows: [Int]
    ) throws -> MLXArray {
        try store.makeLaneLocalRows(key, rows: rows)
    }

    private func quantizedCompanionKey(
        _ key: String,
        suffix: String
    ) -> String {
        if key.hasSuffix(".weight") {
            return String(key.dropLast(".weight".count)) + ".\(suffix)"
        }
        return "\(key).\(suffix)"
    }
}

enum TuringQwenNativeLinearWeight: @unchecked Sendable {
    case dense(MLXArray)
    case quantized(TuringQwenNativeQuantizedLinearWeight)

    func apply(_ input: MLXArray) -> MLXArray {
        switch self {
        case .dense(let weight):
            return matmul(input, weight.T)
        case .quantized(let weight):
            return TuringQwenNativeQuantizedLinear(
                tensorPrefix: "resolved",
                backend: .mlx4bit,
                groupSize: weight.groupSize,
                bits: weight.bits
            )
            .apply(
                input,
                weight: weight.weight,
                scales: weight.scales,
                biases: weight.biases
            )
        }
    }
}

struct TuringQwenNativeQuantizedLinearWeight: @unchecked Sendable {
    let weight: MLXArray
    let scales: MLXArray
    let biases: MLXArray?
    let groupSize: Int
    let bits: Int
}
