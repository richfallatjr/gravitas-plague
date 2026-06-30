import Foundation
import MLX

enum TuringQwenNativeMaterializer {
    static func ownedCacheTensor(
        _ array: MLXArray,
        label: String
    ) throws -> MLXArray {
        guard array.shape.contains(0) == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Cannot retain empty cache tensor \(label) with shape \(array.shape)."
            )
        }

        eval(array)
        return array
    }
}
