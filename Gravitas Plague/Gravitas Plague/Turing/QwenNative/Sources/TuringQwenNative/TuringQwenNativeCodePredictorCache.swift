import Foundation
import MLX

struct TuringQwenNativeCodePredictorGenerationState {
    var kvCache: TuringQwenNativeCodePredictorKVCache
    var position: Int
    var lastHiddenState: MLXArray
    var generatedResidualTokenCount: Int
}

struct TuringQwenNativeCodePredictorKVCache {
    struct Layer {
        var key: MLXArray
        var value: MLXArray
        var length: Int
        var capacity: Int

        var activeKeys: MLXArray {
            key[0..., 0..., 0..<length, 0...]
        }

        var activeValues: MLXArray {
            value[0..., 0..., 0..<length, 0...]
        }
    }

    var layers: [Layer]

    var length: Int {
        layers.first?.length ?? 0
    }
}

struct TuringQwenNativeCodePredictorPrefillOutput {
    let logits: MLXArray
    let lastHiddenState: MLXArray
    let state: TuringQwenNativeCodePredictorGenerationState
}

struct TuringQwenNativeCodePredictorStepOutput {
    let logits: MLXArray
    let lastHiddenState: MLXArray
    let state: TuringQwenNativeCodePredictorGenerationState
}

enum TuringQwenNativeCodePredictorKVCacheStore {
    static let blockCapacity = 32

    static func prefillLayer(
        keyStates: MLXArray,
        valueStates: MLXArray,
        layerIndex: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorKVCache.Layer {
        let materializedKeys = try TuringQwenNativeMaterializer.ownedCacheTensor(
            keyStates,
            label: "codePredictor.layer\(layerIndex).prefill.key",
            performanceMode: performanceMode
        )
        let materializedValues = try TuringQwenNativeMaterializer.ownedCacheTensor(
            valueStates,
            label: "codePredictor.layer\(layerIndex).prefill.value",
            performanceMode: performanceMode
        )
        let length = materializedKeys.dim(2)
        let capacity = max(length + blockCapacity, blockCapacity)
        var keys = zeros(
            [materializedKeys.dim(0), materializedKeys.dim(1), capacity, materializedKeys.dim(3)],
            dtype: materializedKeys.dtype
        )
        var values = zeros(
            [materializedValues.dim(0), materializedValues.dim(1), capacity, materializedValues.dim(3)],
            dtype: materializedValues.dtype
        )
        keys[0..., 0..., 0..<length, 0...] = materializedKeys
        values[0..., 0..., 0..<length, 0...] = materializedValues
        if performanceMode.shouldForceEveryEval {
            eval(keys, values)
        }

        return TuringQwenNativeCodePredictorKVCache.Layer(
            key: keys,
            value: values,
            length: length,
            capacity: capacity
        )
    }

    static func appendOneStep(
        layer: TuringQwenNativeCodePredictorKVCache.Layer,
        newKey: MLXArray,
        newValue: MLXArray,
        layerIndex: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorKVCache.Layer {
        let materializedKey = try TuringQwenNativeMaterializer.ownedCacheTensor(
            newKey,
            label: "codePredictor.layer\(layerIndex).step.key",
            performanceMode: performanceMode
        )
        let materializedValue = try TuringQwenNativeMaterializer.ownedCacheTensor(
            newValue,
            label: "codePredictor.layer\(layerIndex).step.value",
            performanceMode: performanceMode
        )
        let nextLength = layer.length + 1
        guard nextLength <= layer.capacity else {
            throw TuringQwenNativeError.invalidConfig(
                "Code predictor KV cache capacity \(layer.capacity) exceeded at layer \(layerIndex), length \(nextLength)."
            )
        }

        var key = layer.key
        var value = layer.value
        key[0..., 0..., layer.length..<nextLength, 0...] = materializedKey
        value[0..., 0..., layer.length..<nextLength, 0...] = materializedValue
        if performanceMode.shouldForceEveryEval {
            eval(key, value)
        }

        return TuringQwenNativeCodePredictorKVCache.Layer(
            key: key,
            value: value,
            length: nextLength,
            capacity: layer.capacity
        )
    }
}
