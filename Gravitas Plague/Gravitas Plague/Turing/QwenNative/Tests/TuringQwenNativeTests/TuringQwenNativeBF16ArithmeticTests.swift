import Foundation
import Metal
import MLX
import MLXFast
import XCTest
@testable import TuringQwenNative

/// Synthetic arithmetic checks only: these do not qualify speech, token parity,
/// device kernels, or a production precision change.
final class TuringQwenNativeBF16ArithmeticTests: XCTestCase {
    private typealias Arithmetic = TuringQwenNativeGenerationArithmetic
    private typealias Policy = TuringQwenNativeExecutionPolicy

    // Fixed before executing the candidate. One BF16 rounding has relative error
    // <= 2^-8 for normal values; allow 2e-6 absolute for FP32 reduction/transcendental
    // error. RoPE and explicit conversion tests instead require exact rounded bits.
    private let bf16RelativeTolerance = 1.0 / 256.0
    private let fp32AbsoluteTolerance = 0.000002

    /// Independent scalar IEEE round-to-nearest, ties-to-even for finite inputs.
    private func bf16Rounded(_ value: Float) -> Float {
        precondition(value.isFinite)
        let bits = value.bitPattern
        let tieBit = (bits >> 16) & 1
        let rounded = (bits &+ 0x7fff &+ tieBit) & 0xffff0000
        return Float(bitPattern: rounded)
    }

    private func assertWithinBF16Rounding(
        _ actual: [Float], reference: [Double],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, reference.count, file: file, line: line)
        for (index, pair) in zip(actual, reference).enumerated() {
            XCTAssertTrue(pair.0.isFinite, "nonfinite element \(index)", file: file, line: line)
            let tolerance = abs(pair.1) * bf16RelativeTolerance + fp32AbsoluteTolerance
            XCTAssertEqual(Double(pair.0), pair.1, accuracy: tolerance,
                           "element \(index)", file: file, line: line)
        }
    }

    func testProductionDefaultsOnlyGenerationArithmeticToBF16AndKeepsExplicitLegacy() throws {
        let production = Policy.production
        let legacy = Policy(arithmetic: .legacy)
        XCTAssertEqual(production, Policy(arithmetic: .bf16Candidate))
        XCTAssertEqual(production.policyVersion, 1)
        XCTAssertEqual(production.arithmetic, .bf16Candidate)
        XCTAssertEqual(production.prefill, .legacyDense)
        XCTAssertEqual(production.predictor, .legacy)
        XCTAssertEqual(production.workspace, .legacy)
        XCTAssertEqual(production.decoderIO, .legacy)
        XCTAssertEqual(production.kernelSet, "existing")
        XCTAssertEqual(production.decoderState, "legacy")
        XCTAssertEqual(Policy(), legacy)
        XCTAssertEqual(legacy.fingerprint, "e8ea0b094ed59b379df86188064de6f029a03dfe6f6126fa635230bb89963b31")
        XCTAssertEqual(production.fingerprint, "f7188d490a7d756b1ebc8c65b754bcd8c2e20ec3e45a6ddd70068f465cf665f3")
        try production.validateImplemented()
        try legacy.validateImplemented()
        XCTAssertEqual(Policy.current, production)
        XCTAssertTrue(Arithmetic.isBF16)
        Policy.$current.withValue(legacy) {
            XCTAssertEqual(Policy.current, legacy)
            XCTAssertFalse(Arithmetic.isBF16)
        }
        XCTAssertEqual(Policy.current, production)
        XCTAssertTrue(Arithmetic.isBF16)
    }

    func testLegacyPoliciesPreserveActivationAndLogitInputIdentity() {
        MLX.Stream.withDefaultStream(.cpu) {
            for mode: Policy.Arithmetic in [.legacy, .legacyWithConversionCache] {
                Policy.$current.withValue(Policy(arithmetic: mode)) {
                    XCTAssertFalse(Arithmetic.isBF16)
                    for dtype: DType in [.float32, .float16, .bfloat16] {
                        let value = MLXArray([Float(0.125), -1.375, 7.25]).asType(dtype)
                        XCTAssertTrue(Arithmetic.activation(value) === value)
                        XCTAssertTrue(Arithmetic.logitInput(value) === value)
                    }
                }
            }
            XCTAssertEqual(Policy.current, .production)
        }
    }

    func testLegacyNormAndSoftmaxRemainBitExact() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            try Policy.$current.withValue(Policy(arithmetic: .legacy)) {
                let value = MLXArray([Float(0.25), -0.5, 1.125, 2.75,
                                      -1.75, 0.125, 3.5, -0.75], [2, 4])
                let weight = MLXArray([Float(0.875), 1.125, -0.625, 1.5])
                let epsilon: Float = 0.000001
                for manual in [false, true] {
                    let expected: MLXArray
                    if manual {
                        let variance = (value * value).mean(axis: -1, keepDims: true)
                        expected = value / sqrt(variance + epsilon) * weight
                    } else {
                        expected = MLXFast.rmsNorm(value, weight: weight, eps: epsilon)
                    }
                    let actual = Arithmetic.rmsNorm(value, weight: weight,
                                                    epsilon: epsilon, forceManual: manual)
                    try withError { eval(expected, actual) }
                    XCTAssertEqual(actual.dtype, expected.dtype)
                    XCTAssertEqual(actual.asData().data, expected.asData().data)
                }
                for precise in [false, true] {
                    let expected = softmax(value, axis: -1, precise: precise)
                    let actual = Arithmetic.attentionProbabilities(value, legacyPrecise: precise)
                    try withError { eval(expected, actual) }
                    XCTAssertEqual(actual.dtype, expected.dtype)
                    XCTAssertEqual(actual.asData().data, expected.asData().data)
                }
            }
        }
    }

    func testCandidateActivationRoundsOnceAndVocabularyInputWidensBeforeHead() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            try Policy.$current.withValue(Policy(arithmetic: .bf16Candidate)) {
                XCTAssertTrue(Arithmetic.isBF16)
                // Include both halfway tie directions, sign, signed zero and scale.
                let values: [Float] = [1.00390625, 1.01171875, -1.00390625,
                                       -1.01171875, 0, -0.0, 0.000031234, 123_456]
                let expected = values.map(bf16Rounded)
                let input = MLXArray(values, [2, 4])
                let activation = Arithmetic.activation(input)
                let vocabularyInput = Arithmetic.logitInput(activation)
                try withError { eval(activation, vocabularyInput) }
                XCTAssertEqual(activation.dtype, .bfloat16)
                XCTAssertEqual(activation.shape, input.shape)
                XCTAssertEqual(vocabularyInput.dtype, .float32)
                XCTAssertEqual(vocabularyInput.shape, input.shape)
                XCTAssertEqual(activation.asArray(Float.self).map(\.bitPattern),
                               expected.map(\.bitPattern))
                XCTAssertEqual(vocabularyInput.asArray(Float.self).map(\.bitPattern),
                               expected.map(\.bitPattern))
                // The helper must also preserve existing FP32 values without a
                // BF16 detour when an already-wide head input reaches it.
                let wideInput = Arithmetic.logitInput(input)
                try withError { eval(wideInput) }
                XCTAssertEqual(wideInput.asArray(Float.self).map(\.bitPattern),
                               values.map(\.bitPattern))
            }
            XCTAssertEqual(Policy.current, .production)
        }
    }

    private func assertCandidateRMSNorm(forceManual: Bool, stream: MLX.Stream = .cpu) throws {
        try MLX.Stream.withDefaultStream(stream) {
            try Policy.$current.withValue(Policy(arithmetic: .bf16Candidate)) {
                let ordinary: [Float] = [0.12345, -0.97531, 1.001, -2.3751,
                                          3.14159, -0.00031, 8.125, -7.75]
                let highDynamicRange: [Float] = [3e15, -2e14, 6e12, -1e9,
                                                1e-15, -2e-10, 0.03125, -4]
                // A longer reduction mixes one dominant value with many smaller
                // terms, making loss of accumulation precision observable.
                let reduction: [Float] = (0..<256).map { index in
                    index == 0 ? 32 : Float((index % 17) - 8) * 0.03127
                }
                for raw in [ordinary, highDynamicRange, reduction] {
                    let width = raw.count
                    let weight = (0..<width).map { Float(($0 % 9) - 4) * 0.1937 + 0.8123 }
                    let roundedInput = raw.map(bf16Rounded)
                    let roundedWeight = weight.map(bf16Rounded)
                    let epsilon: Float = 0.000001
                    // Double scalar oracle starts from independently BF16-rounded
                    // inputs/weights and carries the reduction without BF16 loss.
                    let meanSquare = roundedInput.reduce(0.0) { $0 + Double($1) * Double($1) }
                        / Double(width)
                    let denominator = Foundation.sqrt(meanSquare + Double(epsilon))
                    let expected = zip(roundedInput, roundedWeight).map {
                        Double($0) / denominator * Double($1)
                    }
                    let input = MLXArray(roundedInput, [1, width]).asType(.bfloat16)
                    let weights = MLXArray(roundedWeight).asType(.bfloat16)
                    let actual = Arithmetic.rmsNorm(input, weight: weights,
                                                    epsilon: epsilon, forceManual: forceManual)
                    try withError { eval(actual) }
                    XCTAssertEqual(actual.dtype, .bfloat16)
                    XCTAssertEqual(actual.shape, [1, width])
                    assertWithinBF16Rounding(actual.asArray(Float.self), reference: expected)
                }
            }
        }
    }

    func testCandidateManualRMSNormUsesWideReductionAgainstScalarReference() throws {
        try assertCandidateRMSNorm(forceManual: true)
    }

    func testCandidateFastRMSNormUsesWideReductionAgainstScalarReference() throws {
        try assertCandidateRMSNorm(forceManual: false)
    }

    func testCandidateMaskedSoftmaxMatchesWideReferenceAndKeepsProbabilityMass() throws {
        try assertCandidateMaskedSoftmax(stream: .cpu)
    }

    private func assertCandidateMaskedSoftmax(stream: MLX.Stream) throws {
        try MLX.Stream.withDefaultStream(stream) {
            try Policy.$current.withValue(Policy(arithmetic: .bf16Candidate)) {
                let scores: [Float] = [100, 99.5, 98.75, -30, 0, 1, 2, 3,
                                        -1.125, 0.125, 1.75, 3.5, -2, 4, 0, 8,
                                        0, 0, 0, 0, 0, 0, 0, 0]
                let width = 8
                let allowedCounts = [4, 6, 3]
                let mask = allowedCounts.flatMap { count in
                    (0..<width).map { $0 < count ? Float(0) : Float(-1_000_000_000) }
                }
                let masked = MLXArray(scores, [3, width]) + MLXArray(mask, [3, width])
                let wideReference = softmax(masked.asType(.float32), axis: -1, precise: true)
                let actual = Arithmetic.attentionProbabilities(masked, legacyPrecise: false)
                try withError { eval(wideReference, actual) }
                XCTAssertEqual(actual.dtype, .bfloat16)
                let values = actual.asArray(Float.self)
                assertWithinBF16Rounding(values,
                                        reference: wideReference.asArray(Float.self).map(Double.init))
                for row in allowedCounts.indices {
                    let count = allowedCounts[row]
                    let rowScores = (0..<count).map { Double(scores[row * width + $0]) }
                    let maximum = try XCTUnwrap(rowScores.max())
                    let exponentials = rowScores.map { Foundation.exp($0 - maximum) }
                    let denominator = exponentials.reduce(0, +)
                    let independent = exponentials.map { $0 / denominator }
                        + [Double](repeating: 0, count: width - count)
                    let rowValues = Array(values[(row * width)..<((row + 1) * width)])
                    assertWithinBF16Rounding(rowValues, reference: independent)
                    XCTAssertEqual(rowValues.reduce(0.0) { $0 + Double($1) }, 1,
                                   accuracy: bf16RelativeTolerance + 4 * fp32AbsoluteTolerance)
                    for column in count..<width {
                        XCTAssertEqual(rowValues[column], 0, "masked probability must be zero")
                    }
                    XCTAssertTrue(rowValues.allSatisfy { $0 >= 0 && $0 <= 1 })
                }
            }
        }
    }

    private func requireOptInMetalTests() throws {
        guard ProcessInfo.processInfo.environment["QWEN_BF16_TEST_GPU"] == "1" else {
            throw XCTSkip("Set QWEN_BF16_TEST_GPU=1 to run synthetic Metal arithmetic checks")
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable")
        }
    }

    func testCandidateGPURMSNormUsesSameIndependentOracleAndTolerance() throws {
        try requireOptInMetalTests()
        try assertCandidateRMSNorm(forceManual: false, stream: .gpu)
        try assertCandidateRMSNorm(forceManual: true, stream: .gpu)
    }

    func testCandidateGPUMaskedSoftmaxUsesSameIndependentOracleAndTolerance() throws {
        try requireOptInMetalTests()
        try assertCandidateMaskedSoftmax(stream: .gpu)
    }

    func testCandidateWeightStorePreservesRawTensorsWithoutC1ConversionCache() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            let packed = MLXArray([UInt32(0x76543210), 0xfedcba98], [1, 2])
            let scales = MLXArray([Float(0.12345), -0.76543], [1, 2]).asType(.bfloat16)
            let biases = MLXArray([Float(-0.00321), 0.01234], [1, 2]).asType(.bfloat16)
            let norm = MLXArray([Float(0.999), 1.001]).asType(.bfloat16)
            let dense = MLXArray([Float(0.1234567), -0.7654321], [1, 2])
            let arrays = [
                "talker.model.layers.0.self_attn.q_proj.weight": packed,
                "talker.model.layers.0.self_attn.q_proj.scales": scales,
                "talker.model.layers.0.self_attn.q_proj.biases": biases,
                "talker.model.layers.0.input_layernorm.weight": norm,
                "fixture.fp32.weight": dense,
            ]
            try withError { eval(packed, scales, biases, norm, dense) }
            let originalBytes = arrays.mapValues { $0.asData().data }
            let store = try Policy.$current.withValue(Policy(arithmetic: .bf16Candidate)) {
                try TuringQwenNativeWeightsStore(
                    arrays: arrays, arithmetic: Policy.current.arithmetic,
                    modelRevision: "bf16-raw-fixture-v1", executionStream: .cpu,
                    recoveryGeneration: nil)
            }
            XCTAssertEqual(store.tensorCount, arrays.count)
            XCTAssertNil(store.conversionCache)
            XCTAssertNil(store.conversionCacheSnapshot)
            for (key, original) in arrays {
                let loaded = try store.require(key)
                XCTAssertTrue(loaded === original, key)
                XCTAssertEqual(loaded.dtype, original.dtype, key)
                XCTAssertEqual(loaded.shape, original.shape, key)
                XCTAssertEqual(loaded.asData().data, originalBytes[key], key)
            }
        }
    }

    private func smallConfig() throws -> TuringQwenNativeConfig {
        let json = #"""
        {
          "model_type": "qwen3_tts", "tts_model_type": "base",
          "tts_bos_token_id": 1, "tts_eos_token_id": 2, "tts_pad_token_id": 0,
          "talker_config": {
            "hidden_size": 8, "text_hidden_size": 8, "text_vocab_size": 32,
            "vocab_size": 32, "num_code_groups": 4, "num_hidden_layers": 1,
            "num_attention_heads": 1, "num_key_value_heads": 1, "head_dim": 8,
            "intermediate_size": 16, "rms_norm_eps": 0.000001,
            "rope_theta": 1000000, "codec_language_id": {"english": 3},
            "codec_think_id": 4, "codec_think_bos_id": 5,
            "codec_think_eos_id": 6, "codec_pad_id": 0,
            "codec_bos_id": 1, "codec_eos_token_id": 2,
            "code_predictor_config": {"head_dim": 8, "rope_theta": 10000,
                                      "num_code_groups": 4}
          }
        }
        """#
        return try JSONDecoder().decode(TuringQwenNativeConfig.self, from: Data(json.utf8))
    }

    private func makeCache(position: Int) throws -> TuringQwenNativeSegmentRuntimeCache {
        TuringQwenNativeSegmentRuntimeCache(
            config: try smallConfig(), promptSequenceLength: position, maxNewRows: 2,
            trailingTextHidden: MLXArray([Float](repeating: 0.12345, count: 8), [1, 1, 8]),
            ttsPadEmbed: MLXArray([Float](repeating: -0.23456, count: 8), [1, 1, 8]))
    }

    func testCandidateRotaryCacheComputesHighPositionsBeforeBF16Rounding() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            try Policy.$current.withValue(Policy(arithmetic: .bf16Candidate)) {
                for position in [257, 4097, 65_537] {
                    let cache = try makeCache(position: position)
                    for offset in 0..<2 {
                        let actualPosition = position + offset
                        let pair = try XCTUnwrap(cache.talkerRope(position: actualPosition))
                        try withError { eval(pair.cos, pair.sin) }
                        XCTAssertEqual(pair.cos.dtype, .bfloat16)
                        XCTAssertEqual(pair.sin.dtype, .bfloat16)
                        XCTAssertEqual(pair.cos.shape, [1, 1, 1, 8])
                        let angles = (0..<4).map {
                            Double(actualPosition) / Foundation.pow(1_000_000, Double($0) / 4)
                        }
                        let cosHalf = angles.map { bf16Rounded(Float(Foundation.cos($0))) }
                        let sinHalf = angles.map { bf16Rounded(Float(Foundation.sin($0))) }
                        XCTAssertEqual(pair.cos.asArray(Float.self).map(\.bitPattern),
                                       (cosHalf + cosHalf).map(\.bitPattern))
                        XCTAssertEqual(pair.sin.asArray(Float.self).map(\.bitPattern),
                                       (sinHalf + sinHalf).map(\.bitPattern))
                        // Unit-frequency channel isolates position quantization:
                        // rounding 4097 to 4096 before trig is a phase error, not
                        // the permitted rounding of the completed sin/cos values.
                        let earlyPosition = Double(bf16Rounded(Float(actualPosition)))
                        let earlyCos = bf16Rounded(Float(Foundation.cos(earlyPosition)))
                        let earlySin = bf16Rounded(Float(Foundation.sin(earlyPosition)))
                        if earlyPosition != Double(actualPosition) {
                            XCTAssertGreaterThan(max(abs(cosHalf[0] - earlyCos),
                                                     abs(sinHalf[0] - earlySin)), 0.1)
                        }
                    }
                }
            }
        }
    }

    func testSegmentCacheKeepsBoundaryDTypesAndRejectsEveryCrossPolicyLookup() throws {
        try MLX.Stream.withDefaultStream(.cpu) {
            for builtMode: Policy.Arithmetic in [.legacy, .legacyWithConversionCache, .bf16Candidate] {
                let cache = try Policy.$current.withValue(Policy(arithmetic: builtMode)) {
                    try makeCache(position: 257)
                }
                for lookupMode: Policy.Arithmetic in [.legacy, .legacyWithConversionCache, .bf16Candidate] {
                    try Policy.$current.withValue(Policy(arithmetic: lookupMode)) {
                        if builtMode != lookupMode {
                            XCTAssertFalse(cache.matchesCurrentArithmetic)
                            XCTAssertNil(cache.talkerRope(position: 257))
                            XCTAssertNil(cache.codePredictorRope(position: 2))
                            XCTAssertNil(cache.talkerTrailingTextEmbed(generationStep: 0))
                            XCTAssertNil(cache.talkerTrailingTextEmbed(generationStep: 1))
                        } else {
                            XCTAssertTrue(cache.matchesCurrentArithmetic)
                            let dtype: DType = builtMode == .bf16Candidate ? .bfloat16 : .float32
                            XCTAssertEqual(try XCTUnwrap(cache.talkerRope(position: 257)).cos.dtype, dtype)
                            XCTAssertEqual(try XCTUnwrap(cache.codePredictorRope(position: 2)).sin.dtype, dtype)
                            XCTAssertEqual(cache.codePredictorPrefillRope.cos.dtype, dtype)
                            XCTAssertEqual(cache.codePredictorPrefillRope.sin.dtype, dtype)
                            let trailing = try XCTUnwrap(cache.talkerTrailingTextEmbed(generationStep: 0))
                            let padding = try XCTUnwrap(cache.talkerTrailingTextEmbed(generationStep: 1))
                            XCTAssertEqual(trailing.dtype, dtype)
                            XCTAssertEqual(padding.dtype, dtype)
                            XCTAssertEqual(cache.codePredictorPrefillMask.dtype, .float32)
                            try withError { eval(trailing, padding, cache.codePredictorPrefillMask) }
                            let expectedTrailing: Float = builtMode == .bf16Candidate
                                ? bf16Rounded(0.12345) : 0.12345
                            let expectedPadding: Float = builtMode == .bf16Candidate
                                ? bf16Rounded(-0.23456) : -0.23456
                            XCTAssertEqual(trailing.asArray(Float.self), [Float](repeating: expectedTrailing, count: 8))
                            XCTAssertEqual(padding.asArray(Float.self), [Float](repeating: expectedPadding, count: 8))
                            XCTAssertEqual(cache.codePredictorPrefillMask.asArray(Float.self),
                                           [0, -1_000_000_000, 0, 0])
                            XCTAssertNil(cache.talkerRope(position: 256))
                            XCTAssertNil(cache.codePredictorRope(position: 4))
                            XCTAssertNil(cache.talkerTrailingTextEmbed(generationStep: 2))
                        }
                    }
                }
            }
        }
    }
}
