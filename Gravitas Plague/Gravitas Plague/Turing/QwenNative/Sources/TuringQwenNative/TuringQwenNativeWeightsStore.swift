import Foundation
import MLX

final class TuringQwenNativeWeightsStore: @unchecked Sendable {
    let identity = UUID()
    private let arraysByKey: [String: MLXArray]
    let tensorCount: Int
    let conversionCache: TuringQwenNativeConversionCache?

    var conversionCacheSnapshot: TuringQwenNativeConversionCacheSnapshot? {
        conversionCache?.snapshot()
    }

    init(modelRoot: URL,
         arithmetic: TuringQwenNativeExecutionPolicy.Arithmetic = TuringQwenNativeExecutionPolicy.current.arithmetic) throws {
        let candidate = arithmetic == .legacyWithConversionCache
        let modelURL = modelRoot.appendingPathComponent("model.safetensors")
        let sourceHandle = candidate ? try FileHandle(forReadingFrom: modelURL) : nil
        defer { try? sourceHandle?.close() }
        let sourceIdentity = try sourceHandle.map {
            try TuringQwenNativeSafetensorsFileIdentity.capture(descriptor: $0.fileDescriptor)
        }
        let loaded = try MLX.loadArrays(
            url: modelURL,
            stream: .cpu
        )
        guard loaded.isEmpty == false else {
            throw TuringQwenNativeError.invalidSafetensors(
                "model.safetensors contains no arrays."
            )
        }
        arraysByKey = loaded
        tensorCount = loaded.count
        if candidate, let sourceIdentity, let sourceHandle {
            func validateSourceIdentity() throws {
                // MLX opens the pathname separately. Inspect both the held
                // descriptor and a fresh path open so atomic replacement is
                // rejected as well as in-place mutation.
                let currentPath = try FileHandle(forReadingFrom: modelURL)
                defer { try? currentPath.close() }
                guard try TuringQwenNativeSafetensorsFileIdentity.capture(descriptor: sourceHandle.fileDescriptor) == sourceIdentity,
                      try TuringQwenNativeSafetensorsFileIdentity.capture(descriptor: currentPath.fileDescriptor) == sourceIdentity else {
                    throw TuringQwenNativeError.invalidSafetensors("Model weights changed while preparing conversion cache.")
                }
            }
            try validateSourceIdentity()
            let recovery = try? TuringMetalRecovery.snapshot()
            let epoch = TuringMetalDiagnostics.failureEpoch
            let cache = try TuringQwenNativeConversionCache(
                arrays: loaded, weightStoreID: identity,
                modelRevision: "\(modelURL.standardizedFileURL.path)|\(sourceIdentity)",
                executionStream: StreamOrDevice.default.stream,
                recoveryGeneration: recovery?.state == .ready ? recovery?.generation : nil,
                failureEpoch: epoch
            )
            try validateSourceIdentity()
            guard epoch == TuringMetalDiagnostics.failureEpoch else {
                throw TuringQwenNativeError.invalidConfig("Metal failure invalidated conversion-cache owner during load.")
            }
            conversionCache = cache
            let snapshot = cache.snapshot()
            print("[TuringQwenNative] C1 conversion cache status=\(snapshot.status) reason=\(snapshot.reason ?? "none") owner=\(identity) tensors=\(snapshot.materializedTensorCount) retainedBytes=\(snapshot.retainedBytes)")
        } else {
            conversionCache = nil
        }

        print("""
        [TuringQwenNative] resident weights loaded
          tensorCount: \(tensorCount)
          source: MLX.loadArrays
          runtimePerStepFileIO: false
        """)
    }

    /// Tiny in-memory fixtures exercise the same transaction and resolver as
    /// resident loading without loading/dequantizing the production model.
    init(
        arrays: [String: MLXArray],
        arithmetic: TuringQwenNativeExecutionPolicy.Arithmetic,
        modelRevision: String,
        executionStream: MLX.Stream,
        recoveryGeneration: UInt64?,
        failureEpoch: UInt64 = TuringMetalDiagnostics.failureEpoch,
        byteBudget: Int = TuringQwenNativeConversionCache.maximumBytes
    ) throws {
        arraysByKey = arrays
        tensorCount = arrays.count
        conversionCache = arithmetic == .legacyWithConversionCache
            ? try TuringQwenNativeConversionCache(
                arrays: arrays, weightStoreID: identity, modelRevision: modelRevision,
                executionStream: executionStream, recoveryGeneration: recoveryGeneration,
                failureEpoch: failureEpoch, byteBudget: byteBudget
            ) : nil
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
