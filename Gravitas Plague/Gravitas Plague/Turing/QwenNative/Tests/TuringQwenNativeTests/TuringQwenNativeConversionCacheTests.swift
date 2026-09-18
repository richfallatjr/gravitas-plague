import Foundation
import Metal
import MLX
import XCTest
@testable import TuringQwenNative

final class TuringQwenNativeConversionCacheTests: XCTestCase {
    private typealias Cache = TuringQwenNativeConversionCache
    private let key = "talker.code_predictor.model.layers.0.self_attn.q_proj.weight"
    private let fixtureBytes = 51 * 2 * 8 * 2 * 4

    private func fixture() -> [String: MLXArray] {
        let packed = MLXArray((0..<(8 * 16)).map { UInt32($0 % 2 == 0 ? 0x76543210 : 0xfedcba98) }, [8, 16])
        let scales = MLXArray((0..<16).map { Float($0 + 1) / 64 }, [8, 2])
            .asType(.bfloat16, stream: .cpu)
        let biases = MLXArray((0..<16).map { Float($0 - 8) / 32 }, [8, 2])
            .asType(.bfloat16, stream: .cpu)
        eval(scales, biases)
        var arrays: [String: MLXArray] = [:]
        for weightKey in Cache.predictorWeightKeys {
            arrays[weightKey] = packed
            arrays[Cache.companionKey(weightKey, "scales")] = scales
            arrays[Cache.companionKey(weightKey, "biases")] = biases
        }
        return arrays
    }

    private func store(
        _ arrays: [String: MLXArray],
        arithmetic: TuringQwenNativeExecutionPolicy.Arithmetic = .legacyWithConversionCache,
        stream: MLX.Stream = .cpu,
        generation: UInt64? = 1,
        budget: Int = Cache.maximumBytes
    ) throws -> TuringQwenNativeWeightsStore {
        try TuringQwenNativeWeightsStore(
            arrays: arrays, arithmetic: arithmetic, modelRevision: "fixture-v1",
            executionStream: stream, recoveryGeneration: generation,
            byteBudget: budget
        )
    }

    func testExactBF16WideningPreservesOriginalsAndPackedWeights() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            var arrays = fixture()
            let bits: [UInt16] = [0, 0x8000, 1, 0x8001, 0x007f, 0x807f, 0x0080, 0x8080,
                                  0x3f80, 0xbf80, 0x3eab, 0xbeab, 0x7f7f, 0xff7f, 0x4000, 0xc000]
            let raw = bits.withUnsafeBytes { Data($0) }
            let original = MLXArray(raw, [8, 2], dtype: .bfloat16)
            arrays[Cache.companionKey(key, "scales")] = original
            let packed = try XCTUnwrap(arrays[key])
            let owner = try store(arrays)
            let cache = try XCTUnwrap(owner.conversionCache)
            let pair = try XCTUnwrap(cache.pair(for: key, inputDType: .float32, groupSize: 64, bits: 4))
            XCTAssertEqual(pair.scales.asArray(Float.self).map(\.bitPattern), bits.map { UInt32($0) << 16 })
            XCTAssertEqual(pair.scales.dtype, .float32)
            XCTAssertEqual(try owner.require(Cache.companionKey(key, "scales")).asData().data, raw)
            XCTAssertTrue(try owner.require(Cache.companionKey(key, "scales")) === original)
            XCTAssertTrue(try owner.require(key) === packed)
            XCTAssertEqual(try owner.require(key).dtype, .uint32)
            let repeated = try XCTUnwrap(cache.pair(for: key, inputDType: .float32, groupSize: 64, bits: 4))
            XCTAssertTrue(repeated.scales === pair.scales)
            XCTAssertTrue(repeated.biases === pair.biases)
            XCTAssertEqual(owner.conversionCacheSnapshot?.materializedTensorCount, 102)
            XCTAssertEqual(owner.conversionCacheSnapshot?.cacheHits, 2)
        }
    }

    private func assertMatmulParity(stream: MLX.Stream) throws {
        try MLX.Stream.withDefaultStream(stream) {
            let arrays = fixture()
            let candidate = try store(arrays, stream: stream)
            let legacy = try store(arrays, arithmetic: .legacy, stream: stream)
            let candidateWeight = try TuringQwenNativeWeightResolver(store: candidate).linear(key)
            let legacyWeight = try TuringQwenNativeWeightResolver(store: legacy).linear(key)
            let values = (0..<128).map { Float(($0 % 13) - 6) / 16 }
            let scales = try XCTUnwrap(arrays[Cache.companionKey(key, "scales")]).asArray(Float.self)
            let biases = try XCTUnwrap(arrays[Cache.companionKey(key, "biases")]).asArray(Float.self)
            let packed = try XCTUnwrap(arrays[key]).asArray(UInt32.self)
            // Independent scalar affine reference, only for this tiny fixture.
            let reference = (0..<8).map { row -> Float in
                (0..<128).reduce(Float.zero) { sum, column in
                    let code = (packed[row * 16 + column / 8] >> ((column % 8) * 4)) & 15
                    return sum + values[column] * (Float(code) * scales[row * 2 + column / 64]
                                                    + biases[row * 2 + column / 64])
                }
            }
            for dtype: DType in [.float32, .float16, .bfloat16] {
                let input = MLXArray(values, [1, 128]).asType(dtype)
                let expected = legacyWeight.apply(input)
                let actual = candidateWeight.apply(input)
                try withError { eval(expected, actual) }
                XCTAssertEqual(actual.dtype, expected.dtype)
                XCTAssertEqual(actual.shape, expected.shape)
                XCTAssertEqual(actual.asData().data, expected.asData().data)
                if dtype != .bfloat16 {
                    XCTAssertEqual(actual.dtype, .float32)
                    XCTAssertEqual(actual.asArray(Float.self), reference)
                } else {
                    XCTAssertEqual(actual.dtype, .bfloat16)
                }
            }
            XCTAssertEqual(candidate.conversionCacheSnapshot?.cacheHits, 2)
            XCTAssertEqual(candidate.conversionCacheSnapshot?.dtypeMisses, 1)
            XCTAssertNil(legacy.conversionCacheSnapshot)
        }
    }

    func testCPUQuantizedMatmulMatchesLegacyAndIndependentReferenceExactly() throws {
        try assertMatmulParity(stream: .cpu)
    }

    func testGPUQuantizedMatmulMatchesLegacyAndIndependentReferenceExactly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        try assertMatmulParity(stream: .gpu)
    }

    func testCPUCachedEdgeFiniteValuesMatchOriginalGPUWideningBits() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        try MLX.Stream.withDefaultStream(.gpu) {
            var arrays = fixture()
            // Signed zeros, subnormals, smallest normals, ordinary positive/
            // negative values and largest finite BF16 values exercise the
            // CPU materialization change independently from quantized matmul.
            let bits: [UInt16] = [0, 0x8000, 1, 0x8001, 0x007f, 0x807f, 0x0080, 0x8080,
                                  0x3f80, 0xbf80, 0x3eab, 0xbeab, 0x7f7f, 0xff7f, 0x4000, 0xc000]
            let raw = bits.withUnsafeBytes { Data($0) }
            let original = MLXArray(raw, [8, 2], dtype: .bfloat16)
            arrays[Cache.companionKey(key, "scales")] = original
            let owner = try store(arrays, stream: .gpu)
            let pair = try XCTUnwrap(owner.conversionCache?.pair(
                for: key, inputDType: .float32, groupSize: 64, bits: 4
            ))
            let originalGPUConversion = original.asType(.float32, stream: .gpu)
            try withError { eval(originalGPUConversion) }
            XCTAssertEqual(pair.scales.asArray(Float.self).map(\.bitPattern),
                           originalGPUConversion.asArray(Float.self).map(\.bitPattern))
        }
    }

    func testDTypeEligibilityDoesNotPromoteBF16IntegerFP64OrComplexInputs() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            let owner = try store(fixture())
            let cache = try XCTUnwrap(owner.conversionCache)
            for dtype: DType in [.bfloat16, .bool, .uint8, .uint16, .uint32, .uint64,
                                .int8, .int16, .int32, .int64, .float64, .complex64] {
                XCTAssertNil(cache.pair(for: key, inputDType: dtype, groupSize: 64, bits: 4))
            }
            XCTAssertEqual(cache.snapshot().dtypeMisses, 12)
            XCTAssertEqual(cache.snapshot().cacheHits, 0)
        }
    }

    func testWholeHotsetTransactionHonorsExactBoundaryAndStrictMaximum() throws {
        let arrays = fixture()
        let boundary = try store(arrays, budget: fixtureBytes)
        XCTAssertEqual(boundary.conversionCacheSnapshot?.status, "materialized")
        XCTAssertEqual(boundary.conversionCacheSnapshot?.retainedBytes, fixtureBytes)
        let rejected = try store(arrays, budget: fixtureBytes - 1)
        XCTAssertEqual(rejected.conversionCacheSnapshot?.reason, "byteBudgetExceeded")
        XCTAssertEqual(rejected.conversionCacheSnapshot?.retainedBytes, 0)
        XCTAssertEqual(rejected.conversionCacheSnapshot?.materializedTensorCount, 0)
        XCTAssertEqual(rejected.conversionCacheSnapshot?.plannedTensorCount, 102)
        XCTAssertEqual(try store(arrays, budget: Int.max).conversionCacheSnapshot?.byteBudget, 16 * 1_024 * 1_024)
        XCTAssertEqual(try store(arrays, budget: -1).conversionCacheSnapshot?.byteBudget, 0)
    }

    func testMissingWrongDTypeAndWrongLayoutRejectTheEntireHotset() throws {
        let arrays = fixture()
        let lastKey = try XCTUnwrap(Cache.predictorWeightKeys.last)
        var missing = arrays
        missing.removeValue(forKey: Cache.companionKey(lastKey, "biases"))
        var dense = arrays
        dense[lastKey] = MLXArray([Float](repeating: 0, count: 8 * 128), [8, 128])
        var wrongDType = arrays
        wrongDType[Cache.companionKey(lastKey, "scales")] = arrays[Cache.companionKey(lastKey, "scales")]?.asType(.float32, stream: .cpu)
        var wrongShape = arrays
        wrongShape[lastKey] = MLXArray([UInt32](repeating: 0, count: 8 * 8), [8, 8])
        for invalid in [missing, dense, wrongDType, wrongShape] {
            let snapshot = try XCTUnwrap(store(invalid).conversionCacheSnapshot)
            XCTAssertEqual(snapshot.status, "ineligible")
            XCTAssertEqual(snapshot.materializedTensorCount, 0)
            XCTAssertEqual(snapshot.retainedBytes, 0)
            XCTAssertTrue(snapshot.reason?.hasPrefix("ineligibleTensorOrLayout:") == true)
        }
    }

    func testTalkerAndDenseWeightsAreNeverCachedOrDequantized() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            var arrays = fixture()
            let talker = "talker.model.layers.0.self_attn.q_proj.weight"
            arrays[talker] = arrays[key]
            arrays[Cache.companionKey(talker, "scales")] = arrays[Cache.companionKey(key, "scales")]
            arrays[Cache.companionKey(talker, "biases")] = arrays[Cache.companionKey(key, "biases")]
            arrays["dense.weight"] = MLXArray([Float](repeating: 1, count: 2 * 128), [2, 128])
            let owner = try store(arrays)
            let resolver = TuringQwenNativeWeightResolver(store: owner)
            let input = MLXArray([Float](repeating: 1, count: 128), [1, 128])
            eval(try resolver.linear(talker).apply(input), try resolver.linear("dense.weight").apply(input))
            XCTAssertEqual(owner.conversionCacheSnapshot?.eligibilityChecks, 0)
            XCTAssertEqual(owner.conversionCacheSnapshot?.retainedBytes, fixtureBytes)
            XCTAssertTrue(owner.conversionCacheSnapshot?.inventory.allSatisfy {
                $0.sourceTensorKey.hasPrefix("talker.code_predictor.") && !$0.sourceTensorKey.hasSuffix(".weight")
            } == true)
        }
    }

    func testIndependentOwnersGenerationsAndContextsNeverReuseCopies() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            let arrays = fixture()
            let first = try store(arrays, generation: 1)
            let second = try store(arrays, generation: 2)
            let firstCache = try XCTUnwrap(first.conversionCache)
            let secondCache = try XCTUnwrap(second.conversionCache)
            let a = try XCTUnwrap(firstCache.pair(for: key, inputDType: .float32, groupSize: 64, bits: 4))
            let b = try XCTUnwrap(secondCache.pair(for: key, inputDType: .float32, groupSize: 64, bits: 4))
            XCTAssertFalse(a.scales === b.scales)
            XCTAssertFalse(a.biases === b.biases)
            XCTAssertNotEqual(first.identity, second.identity)
            XCTAssertEqual(firstCache.snapshot().recoveryGeneration, 1)
            XCTAssertEqual(secondCache.snapshot().recoveryGeneration, 2)
            XCTAssertNil(firstCache.pair(for: key, inputDType: .float32, groupSize: 64, bits: 4,
                                        stream: MLX.Stream(.cpu)))
            XCTAssertNil(firstCache.pair(for: key, inputDType: .float32, groupSize: 64, bits: 4,
                                        currentFailureEpoch: TuringMetalDiagnostics.failureEpoch + 1))
            XCTAssertNil(firstCache.pair(for: key, inputDType: .float32, groupSize: 32, bits: 4))
            XCTAssertEqual(firstCache.snapshot().contextMisses, 1)
            XCTAssertEqual(firstCache.snapshot().staleGenerationMisses, 1)
            XCTAssertEqual(firstCache.snapshot().unavailableMisses, 1)
            let unavailable = try store(arrays, generation: nil)
            XCTAssertEqual(unavailable.conversionCacheSnapshot?.reason, "recoveryGenerationUnavailable")
            XCTAssertEqual(unavailable.conversionCacheSnapshot?.materializedTensorCount, 0)
        }
    }

    func testDestroyedOwnerReleasesCacheWhileAlreadyBuiltLazyOutputRemainsValid() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            let arrays = fixture()
            weak var releasedStore: TuringQwenNativeWeightsStore?
            weak var releasedCache: Cache?
            let result: MLXArray = try autoreleasepool {
                let owner = try store(arrays)
                releasedStore = owner
                releasedCache = owner.conversionCache
                let weight = try TuringQwenNativeWeightResolver(store: owner).linear(key)
                return weight.apply(MLXArray([Float](repeating: 1, count: 128), [1, 128]))
            }
            XCTAssertNil(releasedStore)
            XCTAssertNil(releasedCache)
            let legacy = try store(arrays, arithmetic: .legacy)
            let expected = try TuringQwenNativeWeightResolver(store: legacy).linear(key)
                .apply(MLXArray([Float](repeating: 1, count: 128), [1, 128]))
            eval(result, expected)
            XCTAssertEqual(result.asData().data, expected.asData().data)
        }
    }

    func testCancellationDoesNotPublishPartialCacheAndProductionRemainsLegacy() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MLX.Stream.withDefaultStream(.cpu) {
                try TuringQwenNativeWeightsStore(
                    arrays: [:], arithmetic: .legacyWithConversionCache,
                    modelRevision: "cancelled-fixture", executionStream: .cpu,
                    recoveryGeneration: 1
                )
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled conversion construction must not publish a partial cache")
        } catch is CancellationError {
        }
        XCTAssertEqual(TuringQwenNativeExecutionPolicy.production.arithmetic, .legacy)
        XCTAssertNoThrow(try TuringQwenNativeExecutionPolicy(arithmetic: .legacyWithConversionCache).validateImplemented())
        XCTAssertThrowsError(try TuringQwenNativeExecutionPolicy(arithmetic: .bf16Candidate).validateImplemented())
    }
}
