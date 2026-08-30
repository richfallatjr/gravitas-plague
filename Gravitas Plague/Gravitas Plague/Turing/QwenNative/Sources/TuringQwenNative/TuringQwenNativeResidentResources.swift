import Foundation

public final class TuringQwenNativeResidentResources: @unchecked Sendable {
    public let resourceID = UUID()
    public let modelID: String
    public let quantization: String
    public let modelRoot: URL
    let config: TuringQwenNativeConfig
    let weightsStore: TuringQwenNativeWeightsStore
    let talkerWeights: TuringQwenNativeTalkerResolvedWeights
    let codePredictorWeights: TuringQwenNativeCodePredictorResolvedWeights
    let loadMetrics: TuringQwenNativeResidentResourceLoadMetrics

    public convenience init(
        modelRoot: URL,
        weightBackend: TuringQwenNativeWeightBackend = .baseCloneRuntime
    ) throws {
        try self.init(
            modelRoot: modelRoot,
            weightBackend: weightBackend,
            metricsRecorder: nil
        )
    }

    init(
        modelRoot: URL,
        weightBackend: TuringQwenNativeWeightBackend = .baseCloneRuntime,
        metricsRecorder: TuringQwenNativeResidencyMetricsRecorder?
    ) throws {
        self.modelRoot = modelRoot
        let started = Date()
        let before = metricsRecorder?.record("owner.beforeConfig") ?? .capture()
        try Task.checkCancellation()

        let loadedConfig = try TuringQwenNativeConfig.load(from: modelRoot)
        try loadedConfig.validateBaseCloneRuntime()
        let afterConfig = metricsRecorder?.record("owner.afterConfig") ?? .capture()
        try Task.checkCancellation()

        try TuringQwenNativeQuantizedLinear(
            tensorPrefix: "model",
            backend: weightBackend.kind,
            groupSize: loadedConfig.quantization?.groupSize ?? 64,
            bits: loadedConfig.quantization?.bits ?? 4
        ).preflightOnly()
        try Task.checkCancellation()

        let loadedWeights = try TuringQwenNativeWeightsStore(modelRoot: modelRoot)
        let afterWeightStore = metricsRecorder?.record("owner.afterWeightStore") ?? .capture()
        try Task.checkCancellation()

        let resolvedTalker = try TuringQwenNativeTalkerResolvedWeights(
            config: loadedConfig,
            weightsStore: loadedWeights
        )
        let afterTalker = metricsRecorder?.record("owner.afterTalkerWeights") ?? .capture()
        try Task.checkCancellation()

        let resolvedCodePredictor = try TuringQwenNativeCodePredictorResolvedWeights(
            config: loadedConfig,
            weightsStore: loadedWeights
        )
        let afterCodePredictor = metricsRecorder?.record("owner.afterCodePredictorWeights") ?? .capture()
        try Task.checkCancellation()

        config = loadedConfig
        weightsStore = loadedWeights
        talkerWeights = resolvedTalker
        codePredictorWeights = resolvedCodePredictor
        modelID = "qwen3-tts-12hz-1.7b-base-4bit"
        quantization = "\(loadedConfig.quantization?.bits ?? 0)bit"
        let ready = metricsRecorder?.record("owner.resourcesReady") ?? .capture()
        loadMetrics = TuringQwenNativeResidentResourceLoadMetrics(
            elapsedSeconds: Date().timeIntervalSince(started),
            before: before,
            afterConfig: afterConfig,
            afterWeightStore: afterWeightStore,
            afterTalkerWeights: afterTalker,
            afterCodePredictorWeights: afterCodePredictor,
            ready: ready
        )

        print("""
        [TuringQwenNativeResidentResources] loaded
          resourceID: \(resourceID.uuidString)
          modelID: \(modelID)
          quantization: \(quantization)
          weightStoreID: \(weightsStore.identity.uuidString)
          tensorCount: \(weightsStore.tensorCount)
          immutableResources: true
        """)
    }
}
