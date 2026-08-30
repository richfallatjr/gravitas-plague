import Foundation
import MLX

final class TuringQwenNativeWeightsStore: @unchecked Sendable {
    let identity = UUID()
    private let arraysByKey: [String: MLXArray]
    let tensorCount: Int

    init(modelRoot: URL) throws {
        let loaded = try MLX.loadArrays(
            url: modelRoot.appendingPathComponent("model.safetensors"),
            stream: .cpu
        )
        guard loaded.isEmpty == false else {
            throw TuringQwenNativeError.invalidSafetensors(
                "model.safetensors contains no arrays."
            )
        }
        arraysByKey = loaded
        tensorCount = loaded.count

        print("""
        [TuringQwenNative] resident weights loaded
          tensorCount: \(tensorCount)
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

    func optional(_ key: String) -> MLXArray? {
        arraysByKey[key]
    }

    func makeLaneLocalRows(
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
