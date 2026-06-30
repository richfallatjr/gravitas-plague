import Foundation
import MLX

struct TuringQwenNativeKVCache {
    struct Layer {
        var keys: MLXArray
        var values: MLXArray
        var logicalLength: Int
        var capacity: Int

        var activeKeys: MLXArray {
            keys[0..., 0..., 0..<logicalLength, 0...]
        }

        var activeValues: MLXArray {
            values[0..., 0..., 0..<logicalLength, 0...]
        }
    }

    var layers: [Layer]
    var usesMaterializedLayerState: Bool
    var maxNewRows: Int

    static func empty(
        layerCount: Int
    ) -> TuringQwenNativeKVCache {
        TuringQwenNativeKVCache(
            layers: [],
            usesMaterializedLayerState: false,
            maxNewRows: 0
        )
    }
}

enum TuringQwenNativeKVCacheStore {
    static func promptLayer(
        keyStates: MLXArray,
        valueStates: MLXArray,
        maxNewRows: Int,
        layerIndex: Int,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) throws -> TuringQwenNativeKVCache.Layer {
        let materializedKeys = try TuringQwenNativeMaterializer.ownedCacheTensor(
            keyStates,
            label: "layer\(layerIndex).prompt.key",
            performanceMode: performanceMode
        )
        let materializedValues = try TuringQwenNativeMaterializer.ownedCacheTensor(
            valueStates,
            label: "layer\(layerIndex).prompt.value",
            performanceMode: performanceMode
        )
        let logicalLength = materializedKeys.dim(2)
        let capacity = logicalLength + max(maxNewRows, 1) + 8
        var keys = zeros(
            [materializedKeys.dim(0), materializedKeys.dim(1), capacity, materializedKeys.dim(3)],
            dtype: materializedKeys.dtype
        )
        var values = zeros(
            [materializedValues.dim(0), materializedValues.dim(1), capacity, materializedValues.dim(3)],
            dtype: materializedValues.dtype
        )
        keys[0..., 0..., 0..<logicalLength, 0...] = materializedKeys
        values[0..., 0..., 0..<logicalLength, 0...] = materializedValues
        if performanceMode.shouldForceEveryEval {
            eval(keys, values)
        }

        return TuringQwenNativeKVCache.Layer(
            keys: keys,
            values: values,
            logicalLength: logicalLength,
            capacity: capacity
        )
    }

    static func appendOneStep(
        layer: TuringQwenNativeKVCache.Layer,
        newKeys: MLXArray,
        newValues: MLXArray,
        layerIndex: Int,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) throws -> TuringQwenNativeKVCache.Layer {
        let materializedNewKeys = try TuringQwenNativeMaterializer.ownedCacheTensor(
            newKeys,
            label: "layer\(layerIndex).step.key",
            performanceMode: performanceMode
        )
        let materializedNewValues = try TuringQwenNativeMaterializer.ownedCacheTensor(
            newValues,
            label: "layer\(layerIndex).step.value",
            performanceMode: performanceMode
        )
        let nextLength = layer.logicalLength + 1
        guard nextLength <= layer.capacity else {
            throw TuringQwenNativeError.invalidConfig(
                "KV cache capacity \(layer.capacity) exceeded at layer \(layerIndex), length \(nextLength)."
            )
        }

        var keys = layer.keys
        var values = layer.values
        keys[0..., 0..., layer.logicalLength..<nextLength, 0...] = materializedNewKeys
        values[0..., 0..., layer.logicalLength..<nextLength, 0...] = materializedNewValues
        if performanceMode.shouldForceEveryEval {
            eval(keys, values)
        }

        return TuringQwenNativeKVCache.Layer(
            keys: keys,
            values: values,
            logicalLength: nextLength,
            capacity: layer.capacity
        )
    }
}
