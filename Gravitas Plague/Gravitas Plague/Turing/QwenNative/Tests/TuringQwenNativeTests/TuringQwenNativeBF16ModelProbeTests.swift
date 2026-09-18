import CryptoKit
import Foundation
import Metal
import MLX
import XCTest
@testable import TuringQwenNative

/// Explicit, real-model numerical evidence only. This is not a performance run,
/// a sampled-generation equivalence test, or an audio-quality qualification.
final class TuringQwenNativeBF16ModelProbeTests: XCTestCase {
    private struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct TensorSnapshot {
        let name: String
        let dtype: String
        let shape: [Int]
        let values: [Float]
    }

    private struct TensorComparison: Encodable {
        let name: String
        let referenceDType: String
        let observedDType: String
        let shape: [Int]
        let elementCount: Int
        let allFinite: Bool
        let bitwiseEqualAfterFloat32Readback: Bool
        let maximumAbsoluteError: Double
        let rootMeanSquareError: Double
        let referenceRootMeanSquare: Double
        let normalizedRootMeanSquareError: Double?
        let cosineSimilarity: Double?
    }

    private struct LogitSummary: Encodable {
        let dtype: String
        let argmax: Int
        let largest: Double
        let runnerUp: Double
        let topTwoMargin: Double
    }

    private struct Context: Encodable {
        let modelRoot: String
        let bundleRoot: String
        let weightStoreID: String
        let modelWeightsSHA256: String
        let modelConfigurationSHA256: String
        let workloadPath: String
        let workloadFileSHA256: String
        let voiceID: String
        let variantID: String
        let referenceCodesSHA256: String
        let referenceTextTokensSHA256: String
        let speakerEmbeddingSHA256: String
        let fullReferenceRowCount: Int
        let selectedSegmentIndex: Int
        let text: String
        let textSHA256: String
        let metalDeviceName: String
        let stream: String
        let arithmeticOrder: [String]
    }

    private struct Calibration: Encodable {
        let schemaVersion = 1
        let status: String
        let context: Context
        let candidateEvaluated = false
        let requiredLegacyBitwiseEquality = true
        let numericTolerance = 0
        let comparisons: [TensorComparison]
        let firstLogits: LogitSummary
        let repeatLogits: LogitSummary
    }

    private struct CandidateReport: Encodable {
        let schemaVersion = 1
        let status = "OBSERVATIONAL_NOT_QUALIFIED"
        let context: Context
        let calibrationFile: String
        let calibrationSHA256: String
        let comparisons: [TensorComparison]
        let legacyLogits: LogitSummary
        let candidateLogits: LogitSummary
        let pendingGates = [
            "Predeclared candidate numerical error thresholds",
            "Predictor and teacher-forced generated-step comparisons",
            "All production voices and fixed-seed/free-generation coverage",
            "Blinded audio listening, content, pronunciation, identity and prosody",
            "EOS, duration, silence, clipping, noise and segment continuity",
            "Separate undisturbed device performance qualification"
        ]
        let performancePromotionEligible = false
        let sampledTokensCompared = false
        let decoderExecuted = false
    }

    func testRealBigMikePrefillNumericalCalibrationAndBF16Observation() throws {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["QWEN_BF16_PROBE_MODEL_ROOT", "QWEN_BF16_PROBE_BUNDLE_ROOT",
                    "QWEN_BF16_PROBE_OUTPUT_DIRECTORY"]
        guard keys.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
            throw XCTSkip("Real-model BF16 probe is opt-in: supply \(keys.joined(separator: ", "))")
        }
        let urls = try keys.map { key -> URL in
            let path = try XCTUnwrap(environment[key])
            guard path.hasPrefix("/") else {
                throw ProbeError(message: "\(key) must be an explicit absolute path")
            }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let modelRoot = urls[0], bundleRoot = urls[1], output = urls[2]
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Real-model BF16 probe requires a Metal GPU")
        }
        let workloadURL = try findProductionWorkload()
        let workloadData = try Data(contentsOf: workloadURL)
        let workload = try JSONDecoder().decode(TuringQwenPerformanceWorkload.self, from: workloadData)
        try workload.validate()
        guard workload.characterID == "big_mike", workload.voiceID == "big_mike_base_clone_v1",
              workload.requireCompleteSegments == true, let text = workload.segments.first else {
            throw ProbeError(message: "Expected the checked-in full Big Mike production workload")
        }
        let calibrationURL = output.appendingPathComponent("legacy-calibration.json")
        let candidateURL = output.appendingPathComponent("bf16-model-probe.json")
        guard !FileManager.default.fileExists(atPath: calibrationURL.path),
              !FileManager.default.fileExists(atPath: candidateURL.path) else {
            throw ProbeError(message: "Use a fresh output directory; existing probe reports are not overwritten")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try MLX.Stream.withDefaultStream(.gpu) {
            // One immutable, unconverted resident weight store serves all three
            // passes. Legacy calibration is independent of the shipping default;
            // only the prompt, activations and caches are rebuilt for each pass.
            let legacyPolicy = TuringQwenNativeExecutionPolicy(arithmetic: .legacy)
            let resident = try TuringQwenNativeExecutionPolicy.$current.withValue(legacyPolicy) {
                try TuringQwenNativeResidentResources(modelRoot: modelRoot)
            }
            guard resident.weightsStore.conversionCache == nil else {
                throw ProbeError(message: "Real-model C2 probe must not use a C1 conversion cache")
            }
            let profile = try TuringQwenNativeCloneProfileLoader().loadBigMikeBaseCloneProfile(from: bundleRoot)
            let conditioning = try TuringQwenNativeBaseCloneConditioningBuilder().load(profile: profile)
            guard conditioning.artifacts.referenceRowCount == 159 else {
                throw ProbeError(message: "Expected all 159 Big Mike reference rows; no truncation is permitted")
            }
            let tokenizer = try TuringQwenNativeTokenizer(modelRoot: modelRoot)
            let prepared = try TuringQwenNativeBaseCloneInputBuilder.build(
                request: .init(targetText: text, targetLanguage: workload.language,
                               cloneArtifacts: conditioning.artifacts, referenceRowLimit: nil,
                               referenceWindowStrategy: .full),
                config: resident.config, tokenizer: tokenizer
            )
            let context = Context(
                modelRoot: modelRoot.path, bundleRoot: bundleRoot.path,
                weightStoreID: resident.weightsStore.identity.uuidString,
                modelWeightsSHA256: try hashFile(modelRoot.appendingPathComponent("model.safetensors")),
                modelConfigurationSHA256: try hashFile(modelRoot.appendingPathComponent("config.json")),
                workloadPath: workloadURL.path, workloadFileSHA256: hash(workloadData),
                voiceID: profile.voiceID, variantID: profile.defaultVariantID,
                referenceCodesSHA256: try hashFile(conditioning.variant.referenceCodesURL),
                referenceTextTokensSHA256: try hashFile(conditioning.variant.referenceTextTokensURL),
                speakerEmbeddingSHA256: try hashFile(conditioning.variant.speakerEmbeddingURL),
                fullReferenceRowCount: prepared.referenceRowCount, selectedSegmentIndex: 0,
                text: text, textSHA256: hash(Data(text.utf8)), metalDeviceName: metalDevice.name,
                stream: "gpu.default.sequential",
                arithmeticOrder: ["legacy", "legacy", "bf16Candidate"]
            )

            let baseline = try runPass(policy: legacyPolicy, prepared: prepared,
                                       resident: resident, maximumRows: workload.maximumRowsPerSegment)
            let baselineRepeat = try runPass(policy: legacyPolicy, prepared: prepared,
                                             resident: resident, maximumRows: workload.maximumRowsPerSegment)
            let calibrationComparisons = try compare(reference: baseline, observed: baselineRepeat)
            let exact = calibrationComparisons.allSatisfy {
                $0.referenceDType == $0.observedDType && $0.bitwiseEqualAfterFloat32Readback
            }
            let calibration = Calibration(
                status: exact ? "PASS_EXACT_LEGACY_REPEAT" : "FAIL_LEGACY_NONDETERMINISM",
                context: context, comparisons: calibrationComparisons,
                firstLogits: try logitSummary(baseline), repeatLogits: try logitSummary(baselineRepeat)
            )
            let calibrationData = try encode(calibration)
            // This is deliberately committed before any candidate evaluation.
            try calibrationData.write(to: calibrationURL, options: .atomic)
            guard exact else {
                throw ProbeError(message: "Legacy repeat was not bitwise identical; candidate was not executed")
            }
            guard try Data(contentsOf: calibrationURL) == calibrationData else {
                throw ProbeError(message: "Legacy calibration could not be verified before candidate execution")
            }

            let candidate = try runPass(policy: .init(arithmetic: .bf16Candidate), prepared: prepared,
                                        resident: resident, maximumRows: workload.maximumRowsPerSegment)
            let report = CandidateReport(
                context: context, calibrationFile: calibrationURL.lastPathComponent,
                calibrationSHA256: hash(calibrationData),
                comparisons: try compare(reference: baseline, observed: candidate),
                legacyLogits: try logitSummary(baseline), candidateLogits: try logitSummary(candidate)
            )
            try encode(report).write(to: candidateURL, options: .atomic)
            print("[QwenBF16ModelProbe] numerical evidence only: \(candidateURL.path)")
        }
    }

    private func runPass(
        policy: TuringQwenNativeExecutionPolicy,
        prepared: TuringQwenNativePreparedBaseClonePrompt,
        resident: TuringQwenNativeResidentResources,
        maximumRows: Int
    ) throws -> [TensorSnapshot] {
        try policy.validateImplemented()
        return try TuringQwenNativeExecutionPolicy.$current.withValue(policy) {
            try autoreleasepool {
                try withError {
                    let staticContext = try TuringQwenNativeBaseClonePromptInputBuilder.makeStaticContext(
                        prepared: prepared, config: resident.config, weightsStore: resident.weightsStore,
                        codePredictorWeights: resident.codePredictorWeights)
                    let prompt = try TuringQwenNativeBaseClonePromptInputBuilder.build(
                        prepared: prepared, config: resident.config,
                        weightsStore: resident.weightsStore, staticContext: staticContext)
                    let forward = try TuringQwenNativeTalkerForwardRunner.runFullForward(
                        promptInputs: prompt, config: resident.config, weightsStore: resident.weightsStore,
                        maxNewRows: maximumRows, resolvedWeights: resident.talkerWeights,
                        performanceMode: .performance)
                    let logits = TuringQwenNativeTalkerForwardRunner.codecHeadLogits(
                        finalLastHiddenState: forward.finalLastHiddenState,
                        codecHeadWeight: resident.talkerWeights.codecHeadWeight,
                        performanceMode: .performance)
                    guard logits.dtype == .float32 else {
                        throw ProbeError(message: "Vocabulary head did not compute FP32 logits under \(policy.arithmetic)")
                    }
                    let expectedDType: DType = policy.arithmetic == .bf16Candidate ? .bfloat16 : .float32
                    guard prompt.inputsEmbeds.dtype == expectedDType,
                          forward.finalLastHiddenState.dtype == expectedDType else {
                        throw ProbeError(message: "Prompt/final-hidden activation containment failed under \(policy.arithmetic)")
                    }
                    var snapshots = [try snapshot("prompt", prompt.inputsEmbeds),
                                     try snapshot("finalHidden", forward.finalLastHiddenState)]
                    guard forward.kvCache.layers.count == resident.config.talkerConfig.numHiddenLayers else {
                        throw ProbeError(message: "Full forward did not return every layer cache")
                    }
                    for (index, layer) in forward.kvCache.layers.enumerated() {
                        guard layer.logicalLength == prompt.sequenceLength,
                              layer.keys.dtype == expectedDType, layer.values.dtype == expectedDType else {
                            throw ProbeError(message: "Invalid logical cache length or dtype at layer \(index)")
                        }
                        snapshots.append(try snapshot("layer.\(index).validK", layer.activeKeys))
                        snapshots.append(try snapshot("layer.\(index).validV", layer.activeValues))
                    }
                    snapshots.append(try snapshot("codecLogits", logits))
                    return snapshots
                }
            }
        }
    }

    private func snapshot(_ name: String, _ array: MLXArray) throws -> TensorSnapshot {
        let float32 = array.asType(.float32)
        eval(float32)
        let values = float32.asArray(Float.self)
        guard !values.isEmpty, values.count == array.size, values.allSatisfy(\.isFinite) else {
            throw ProbeError(message: "Empty, malformed, or nonfinite real-model tensor: \(name)")
        }
        return .init(name: name, dtype: String(describing: array.dtype), shape: array.shape, values: values)
    }

    private func compare(reference: [TensorSnapshot], observed: [TensorSnapshot]) throws -> [TensorComparison] {
        guard reference.count == observed.count else { throw ProbeError(message: "Tensor count changed") }
        return try zip(reference, observed).map { expected, actual in
            guard expected.name == actual.name, expected.shape == actual.shape,
                  expected.values.count == actual.values.count else {
                throw ProbeError(message: "Tensor name or shape changed: \(expected.name)")
            }
            var maximum = 0.0, squaredError = 0.0, referenceEnergy = 0.0, observedEnergy = 0.0, dot = 0.0
            var exact = true
            for (lhs, rhs) in zip(expected.values, actual.values) {
                let a = Double(lhs), b = Double(rhs), difference = a - b
                maximum = max(maximum, abs(difference))
                squaredError += difference * difference
                referenceEnergy += a * a
                observedEnergy += b * b
                dot += a * b
                exact = exact && lhs.bitPattern == rhs.bitPattern
            }
            let count = Double(expected.values.count)
            let rmse = sqrt(squaredError / count)
            let referenceRMS = sqrt(referenceEnergy / count)
            let cosineDenominator = sqrt(referenceEnergy) * sqrt(observedEnergy)
            return .init(name: expected.name, referenceDType: expected.dtype, observedDType: actual.dtype,
                         shape: expected.shape, elementCount: expected.values.count, allFinite: true,
                         bitwiseEqualAfterFloat32Readback: exact, maximumAbsoluteError: maximum,
                         rootMeanSquareError: rmse, referenceRootMeanSquare: referenceRMS,
                         normalizedRootMeanSquareError: referenceRMS > 0 ? rmse / referenceRMS : nil,
                         cosineSimilarity: cosineDenominator > 0 ? dot / cosineDenominator : nil)
        }
    }

    private func logitSummary(_ snapshots: [TensorSnapshot]) throws -> LogitSummary {
        guard let logits = snapshots.first(where: { $0.name == "codecLogits" }), logits.values.count >= 2 else {
            throw ProbeError(message: "Missing real codec logits")
        }
        let order = logits.values.indices.sorted {
            logits.values[$0] == logits.values[$1] ? $0 < $1 : logits.values[$0] > logits.values[$1]
        }
        let largest = Double(logits.values[order[0]]), runnerUp = Double(logits.values[order[1]])
        return .init(dtype: logits.dtype, argmax: order[0], largest: largest, runnerUp: runnerUp,
                     topTwoMargin: largest - runnerUp)
    }

    private func findProductionWorkload() throws -> URL {
        var ancestor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = ancestor.appendingPathComponent("Tools/Turing/Performance/Workloads/big_mike-production-response-full.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            ancestor.deleteLastPathComponent()
        }
        throw ProbeError(message: "Cannot locate the checked-in full Big Mike workload from this test source")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
