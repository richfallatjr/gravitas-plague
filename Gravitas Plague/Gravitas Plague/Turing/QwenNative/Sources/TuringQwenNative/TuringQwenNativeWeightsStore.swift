import Foundation
import MLX

struct TuringQwenNativeWeightsStore: @unchecked Sendable {
    private let arraysByKey: [String: MLXArray]

    init(modelRoot: URL) throws {
        self.arraysByKey = try MLX.loadArrays(
            url: modelRoot.appendingPathComponent("model.safetensors"),
            stream: .cpu
        )

        print("""
        [TuringQwenNative] resident weights loaded
          tensorCount: \(arraysByKey.count)
          source: MLX.loadArrays
          runtimePerStepFileIO: false
        """)
    }

    func require(_ key: String) throws -> MLXArray {
        guard let array = arraysByKey[key] else {
            throw TuringQwenNativeError.invalidSafetensors("Missing tensor \(key).")
        }

        return array
    }

    func requireRows(
        _ key: String,
        rows: [Int]
    ) throws -> MLXArray {
        let source = try require(key)
        guard source.shape.count == 2 else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Row slicing requires rank-2 tensor \(key), got shape \(source.shape)."
            )
        }

        return source.take(MLXArray(rows), axis: 0)
    }
}
