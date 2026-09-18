import Foundation
import MLX

/// C1 host experiment evidence. Hits count companion selections, not observed
/// Metal conversion kernels. Process memory samples include other live owners.
public struct TuringQwenNativeConversionCacheSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let sourceTensorKey: String
        public let shape: [Int]
        public let sourceDType: String
        public let executionDType: String
        public let groupSize: Int
        public let bits: Int
        public let quantizationLayout: String
        public let plannedFP32Bytes: Int
    }

    public let status: String
    public let reason: String?
    public let weightStoreID: String
    public let modelRevision: String
    public let recoveryGeneration: UInt64?
    public let executionContext: String
    public let materializationContext: String
    public let hotsetID: String
    public let byteBudget: Int
    public let plannedTensorCount: Int
    public let materializedTensorCount: Int
    public let retainedBytes: Int
    public let sourceCompanionBytes: Int
    public let coldMaterializationSeconds: Double
    public let processFootprintBeforeMB: Double
    public let processFootprintAfterMB: Double
    public let inventory: [Entry]
    public var eligibilityChecks: UInt64 = 0
    public var cacheHits: UInt64 = 0
    public var dtypeMisses: UInt64 = 0
    public var contextMisses: UInt64 = 0
    public var staleGenerationMisses: UInt64 = 0
    public var unavailableMisses: UInt64 = 0
}

/// One immutable cache per immutable weight store. There is no global registry,
/// eviction, dense-matrix expansion, lazy refill or cross-owner cache lookup.
/// Only diagnostic counters mutate, and no instance exists in legacy mode.
final class TuringQwenNativeConversionCache: @unchecked Sendable {
    static let maximumBytes = 16 * 1_024 * 1_024
    static let hotsetID = "c1.predictor-affine-bf16-companions.v1"
    static let predictorWeightKeys: [String] = {
        let projections = ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj",
                           "self_attn.o_proj", "mlp.gate_proj", "mlp.up_proj", "mlp.down_proj"]
        let layers = (0..<5).flatMap { layer in
            projections.map { "talker.code_predictor.model.layers.\(layer).\($0).weight" }
        }
        return layers + (0..<15).map { "talker.code_predictor.lm_head.\($0).weight" }
            + ["talker.code_predictor.small_to_mtp_projection.weight"]
    }()

    struct Pair {
        let scales: MLXArray
        let biases: MLXArray
    }

    /// Keys are scoped by this cache's owner/revision/stream/generation. The
    /// remaining dimensions (source key, dtype, layout, group, bits) are fixed
    /// and recorded in inventory; lookup never crosses this owning instance.
    private let pairs: [String: Pair]
    private let executionStream: MLX.Stream
    private let failureEpoch: UInt64
    private let counterLock = NSLock()
    private var evidence: TuringQwenNativeConversionCacheSnapshot

    init(
        arrays: [String: MLXArray],
        weightStoreID: UUID,
        modelRevision: String,
        executionStream: MLX.Stream,
        recoveryGeneration: UInt64?,
        failureEpoch: UInt64,
        byteBudget: Int = maximumBytes
    ) throws {
        try Task.checkCancellation()
        self.executionStream = executionStream
        self.failureEpoch = failureEpoch
        let started = Date()
        let before = TuringQwenNativeProcessMemoryProbe.snapshot().physFootprintMB
        let budget = min(max(0, byteBudget), Self.maximumBytes)
        let plan = Self.plan(arrays: arrays, byteBudget: budget)
        let reason = recoveryGeneration == nil ? "recoveryGenerationUnavailable" : plan.reason
        var converted: [String: Pair] = [:]
        if reason == nil {
            // Validate the complete fixed hotset before allocating any copy.
            // CPU BF16 -> FP32 is an exact widening and avoids introducing a
            // new GPU completion boundary during resident loading. eval makes
            // each immutable copy concrete before publishing this cache.
            try Task.checkCancellation()
            try withError {
                for key in Self.predictorWeightKeys {
                    try Task.checkCancellation()
                    let scales = arrays[Self.companionKey(key, "scales")]!
                        .asType(.float32, stream: .cpu)
                    let biases = arrays[Self.companionKey(key, "biases")]!
                        .asType(.float32, stream: .cpu)
                    eval(scales, biases)
                    converted[key] = Pair(scales: scales, biases: biases)
                }
            }
            try Task.checkCancellation()
        }
        pairs = converted
        evidence = TuringQwenNativeConversionCacheSnapshot(
            status: reason == nil ? "materialized" : "ineligible",
            reason: reason,
            weightStoreID: weightStoreID.uuidString,
            modelRevision: modelRevision,
            recoveryGeneration: recoveryGeneration,
            executionContext: executionStream.description,
            materializationContext: "cpu",
            hotsetID: Self.hotsetID,
            byteBudget: budget,
            plannedTensorCount: Self.predictorWeightKeys.count * 2,
            materializedTensorCount: converted.count * 2,
            retainedBytes: reason == nil ? plan.bytes : 0,
            sourceCompanionBytes: plan.bytes / 2,
            coldMaterializationSeconds: Date().timeIntervalSince(started),
            processFootprintBeforeMB: before,
            processFootprintAfterMB: TuringQwenNativeProcessMemoryProbe.snapshot().physFootprintMB,
            inventory: plan.inventory
        )
    }

    static func companionKey(_ weightKey: String, _ suffix: String) -> String {
        String(weightKey.dropLast(".weight".count)) + "." + suffix
    }

    private static func plan(
        arrays: [String: MLXArray], byteBudget: Int
    ) -> (inventory: [TuringQwenNativeConversionCacheSnapshot.Entry], bytes: Int, reason: String?) {
        var inventory: [TuringQwenNativeConversionCacheSnapshot.Entry] = []
        var bytes = 0
        for key in predictorWeightKeys {
            guard let weight = arrays[key], weight.dtype == .uint32, weight.ndim == 2,
                  let scales = arrays[companionKey(key, "scales")],
                  let biases = arrays[companionKey(key, "biases")],
                  scales.dtype == .bfloat16, biases.dtype == .bfloat16,
                  scales.ndim == 2, scales.shape == biases.shape,
                  weight.dim(0) == scales.dim(0), weight.dim(0) > 0,
                  scales.dim(1) > 0,
                  // 4-bit U32 packing has 8 values/word, affine groups have 64.
                  weight.dim(1).isMultiple(of: 8), weight.dim(1) / 8 == scales.dim(1) else {
                return (inventory, bytes, "ineligibleTensorOrLayout:\(key)")
            }
            let (tensorBytes, overflow) = scales.size.multipliedReportingOverflow(by: 4)
            let (pairBytes, pairOverflow) = tensorBytes.multipliedReportingOverflow(by: 2)
            let (total, totalOverflow) = bytes.addingReportingOverflow(pairBytes)
            guard !overflow, !pairOverflow, !totalOverflow else {
                return (inventory, bytes, "byteCountOverflow:\(key)")
            }
            bytes = total
            for suffix in ["scales", "biases"] {
                inventory.append(.init(
                    sourceTensorKey: companionKey(key, suffix), shape: scales.shape,
                    sourceDType: "bfloat16", executionDType: "float32",
                    groupSize: 64, bits: 4, quantizationLayout: "affine.transpose",
                    plannedFP32Bytes: tensorBytes
                ))
            }
        }
        return (inventory, bytes, bytes <= byteBudget ? nil : "byteBudgetExceeded")
    }

    func snapshot() -> TuringQwenNativeConversionCacheSnapshot {
        counterLock.withLock { evidence }
    }

    func contains(_ weightKey: String) -> Bool {
        // Also attach diagnostics for an ineligible fixed-hotset entry. A
        // fallback must not disappear under a successful candidate label.
        Self.predictorWeightKeys.contains(weightKey)
    }

    /// The vendored dtype.cpp promotion table gives BF16+FP32 -> FP32 and
    /// BF16+FP16 -> FP32. All integral/BF16 inputs retain BF16; FP64/complex
    /// have different promotion and must keep original companions.
    static func originalPromotionIsFP32(inputDType: DType) -> Bool {
        inputDType == .float32 || inputDType == .float16
    }

    func pair(
        for weightKey: String,
        inputDType: DType,
        groupSize: Int,
        bits: Int,
        stream: MLX.Stream = StreamOrDevice.default.stream,
        currentFailureEpoch: UInt64 = TuringMetalDiagnostics.failureEpoch
    ) -> Pair? {
        let selected: Pair?
        enum Outcome { case hit, dtype, context, stale, unavailable }
        let outcome: Outcome
        if currentFailureEpoch != failureEpoch {
            selected = nil
            outcome = .stale
        } else if stream != executionStream {
            selected = nil
            outcome = .context
        } else if !Self.originalPromotionIsFP32(inputDType: inputDType) {
            selected = nil
            outcome = .dtype
        } else if groupSize != 64 || bits != 4 || pairs[weightKey] == nil {
            selected = nil
            outcome = .unavailable
        } else {
            selected = pairs[weightKey]
            outcome = .hit
        }
        counterLock.withLock {
            evidence.eligibilityChecks += 1
            switch outcome {
            case .hit: evidence.cacheHits += 1
            case .dtype: evidence.dtypeMisses += 1
            case .context: evidence.contextMisses += 1
            case .stale: evidence.staleGenerationMisses += 1
            case .unavailable: evidence.unavailableMisses += 1
            }
        }
        return selected
    }
}
