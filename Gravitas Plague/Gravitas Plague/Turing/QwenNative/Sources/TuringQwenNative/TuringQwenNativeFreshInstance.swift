import Foundation

public actor TuringQwenNativeFreshInstance {
    public nonisolated let id: TuringQwenNativeFreshInstanceID

    private var residentResources: TuringQwenNativeResidentResources?
    private var baseCloneEngine: TuringQwenNativeBaseCloneEngine?

    public init(id: TuringQwenNativeFreshInstanceID) {
        self.id = id
    }

    public func warmLoad(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        let resident = try TuringQwenNativeResidentResources(modelRoot: modelRoot)
        let engine = try TuringQwenNativeBaseCloneEngine(
            modelRoot: modelRoot,
            residentResources: resident,
            trace: .stdout(prefix: "[TuringQwenFreshInstances.\(id.rawValue)]")
        )

        self.residentResources = resident
        self.baseCloneEngine = engine

        print("""
        [TuringQwenFreshInstances] instance warm loaded
          instanceID: \(id.rawValue)
          residentResourcesObjectID: \(ObjectIdentifier(resident))
          weightsStoreObjectID: \(id.rawValue).weightsStore
          voiceID: \(cloneProfile.voiceID)
          variantID: \(variantID)
          performanceMode: \(performanceMode.rawValue)
          sharedWeights: false
        """)
    }

    public func generate(
        _ request: TuringQwenNativeBaseCloneSegmentRequest
    ) async throws -> TuringQwenNativeAudio {
        guard let engine = baseCloneEngine else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Fresh Qwen instance \(id.rawValue) is not warm-loaded."
            )
        }

        let prompt = TuringQwenNativeBaseClonePrompt(
            text: request.text,
            language: request.language,
            cloneProfile: request.cloneProfile,
            maxNewRows: request.maxNewRows,
            performanceMode: request.performanceMode,
            referenceRowLimit: request.referenceRowLimit,
            referenceWindowStrategy: request.referenceWindowStrategy
        )

        let audio = try await engine.generateBaseClone(prompt: prompt)
        await releaseRequestLocalState()
        return audio
    }

    public func releaseRequestLocalState() async {
        await baseCloneEngine?.releaseResidentState(
            reason: "\(id.rawValue).requestFinished",
            logMemorySnapshot: false
        )
    }

    public func unload() async {
        await baseCloneEngine?.releaseResidentState(
            reason: "\(id.rawValue).unload",
            logMemorySnapshot: false
        )
        baseCloneEngine = nil
        residentResources = nil
        TuringQwenNativeMemoryControl.clearCache(
            label: "freshInstance.\(id.rawValue).unload",
            shouldLogSnapshot: false
        )
    }
}
