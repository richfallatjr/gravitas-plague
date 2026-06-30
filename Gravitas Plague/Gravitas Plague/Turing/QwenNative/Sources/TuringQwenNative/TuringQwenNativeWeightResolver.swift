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

    func rows(
        _ key: String,
        rows: [Int]
    ) throws -> MLXArray {
        try store.requireRows(key, rows: rows)
    }
}
