#if GR_TURING_QUALIFICATION
import Foundation
import MLX

public struct TuringQwenNativeSharedWeightQualificationSnapshot: Sendable, Equatable, Codable {
    public struct TensorSample: Sendable, Equatable, Codable {
        public let key: String
        public let shape: [Int]
        public let dtype: String
        public let scalarIndices: [Int]
        public let float32BitPatterns: [UInt32]

        public init(
            key: String,
            shape: [Int],
            dtype: String,
            scalarIndices: [Int],
            float32BitPatterns: [UInt32]
        ) {
            self.key = key
            self.shape = shape
            self.dtype = dtype
            self.scalarIndices = scalarIndices
            self.float32BitPatterns = float32BitPatterns
        }
    }

    public let tensors: [TensorSample]

    public init(tensors: [TensorSample]) {
        self.tensors = tensors
    }

    static func deterministicScalarIndices(
        count: Int,
        key: String
    ) throws -> [Int] {
        guard count >= 4 else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Qualification weight tensor \(key) has fewer than four scalars."
            )
        }

        // FNV-1a is deliberately stable across processes, unlike Swift.Hasher.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let seededInterior = 1 + Int(hash % UInt64(count - 2))
        return [0, count / 2, count - 1, seededInterior]
    }
}

extension TuringQwenNativeWeightsStore {
    func makeQualificationSampleSnapshot() throws ->
        TuringQwenNativeSharedWeightQualificationSnapshot
    {
        let representativeKeys = [
            "talker.model.text_embedding.weight",
            "talker.model.layers.0.self_attn.q_proj.weight",
            "talker.model.layers.0.mlp.gate_proj.weight",
            "talker.code_predictor.model.layers.0.self_attn.q_proj.weight"
        ]

        let samples = try representativeKeys.map { key in
            let tensor = try require(key)
            let indices = try TuringQwenNativeSharedWeightQualificationSnapshot
                .deterministicScalarIndices(count: tensor.size, key: key)
            let flattenedTensor = tensor.reshaped([-1], stream: .cpu)
            let values = indices.map { index in
                flattenedTensor[index]
                    .asType(.float32, stream: .cpu)
                    .item(Float.self)
                    .bitPattern
            }
            return TuringQwenNativeSharedWeightQualificationSnapshot.TensorSample(
                key: key,
                shape: tensor.shape,
                dtype: String(describing: tensor.dtype),
                scalarIndices: indices,
                float32BitPatterns: values
            )
        }
        return .init(tensors: samples)
    }
}
#endif
