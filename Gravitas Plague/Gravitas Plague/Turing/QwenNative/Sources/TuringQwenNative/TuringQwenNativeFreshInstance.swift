import Foundation

public actor TuringQwenNativeFreshInstance {
  public nonisolated let id: TuringQwenNativeFreshInstanceID

  private var residentResources: TuringQwenNativeResidentResources?
  private var baseCloneEngine: TuringQwenNativeBaseCloneEngine?

  public init(
    id: TuringQwenNativeFreshInstanceID
  ) {
    self.id = id
  }

  public func warmLoad(
    modelRoot: URL,
    cloneProfile:
      TuringQwenNativeCloneProfile,
    variantID: String,
    performanceMode:
      TuringQwenNativePerformanceMode
  ) async throws {
    try await TuringQwenNativeMetalCircuitBreaker.shared.requireHealthy()
    TuringQwenNativeDiagnostics.recordBreadcrumb(
      "freshInstance.warmLoad.started",
      instanceID: id.rawValue,
      details: [
        "voiceID": cloneProfile.voiceID,
        "variantID": variantID
      ]
    )
    print(
      """
      [TuringQwenFresh2] instance warm load started
        instanceID: \(id.rawValue)
        sharedResidentResources: false
        sharedWeightStore: false
      """)

    let warmContext = TuringQwenNativeMLXExecutionContext(
      runID: "warmLoad.\(variantID)",
      instanceID: id,
      phase: .warmLoad,
      stage: "freshInstance.resourcesAndEngine"
    )
    let (resident, engine) = try TuringQwenNativeMLXErrorBoundary.run(
      context: warmContext
    ) {
      let resident = try TuringQwenNativeResidentResources(
        modelRoot: modelRoot
      )
      let engine = try TuringQwenNativeBaseCloneEngine(
        modelRoot: modelRoot,
        residentResources: resident,
        trace: .stdout(
          prefix: "[TuringQwenFresh2.\(id.rawValue)]"
        )
      )
      return (resident, engine)
    }

    residentResources = resident
    baseCloneEngine = engine

    TuringQwenNativeDiagnostics.recordBreadcrumb(
      "freshInstance.warmLoad.completed",
      instanceID: id.rawValue,
      details: [
        "voiceID": cloneProfile.voiceID,
        "variantID": variantID
      ]
    )

    print(
      """
      [TuringQwenFresh2] instance warm load finished
        instanceID: \(id.rawValue)
        residentResourcesObjectID: \(ObjectIdentifier(resident))
        weightsStoreObjectID: \(id.rawValue).weightsStore
        voiceID: \(cloneProfile.voiceID)
        variantID: \(variantID)
        performanceMode: \(performanceMode.rawValue)
        sharedWeights: false
        sharedWeightStore: false
      """)
  }

  public func renderCodebookAndRelease(
    _ request:
      TuringQwenNativeBaseCloneSegmentRequest,
    runID: String,
    laneIndex: Int? = nil,
    releaseLedger:
      TuringQwenRenderReleaseLedger
  ) async throws -> TuringQwenRenderedCodebookSegment {
    guard
      let engine =
        baseCloneEngine
    else {
      throw
        TuringQwenNativeError
        .nativeGenerationNotImplemented(
          "Fresh Qwen instance \(id.rawValue) is not warm-loaded."
        )
    }

    let materialized = try await TuringQwenNativeMLXErrorBoundary.run(
      context: TuringQwenNativeMLXExecutionContext(
        runID: runID,
        instanceID: id,
        segmentIndex: request.segmentIndex,
        laneIndex: laneIndex,
        phase: .dynamicTalker,
        stage: "baseClone.renderAndMaterialize"
      )
    ) {
      try await engine.materializeRenderedSegmentAndRelease(
        request: request,
        runID: runID,
        instanceID: id,
        laneIndex: laneIndex
      )
    }

    let releaseToken =
      TuringQwenRenderReleaseToken(
        runID: runID,
        segmentIndex:
          request.segmentIndex,
        instanceID: id
      )
    await releaseLedger.record(
      releaseToken
    )

    print(
      """
      [TuringSegmentPipeline] render release committed
        runID: \(runID)
        segmentIndex: \(request.segmentIndex)
        instanceID: \(id.rawValue)
        releaseID: \(releaseToken.releaseID.uuidString)
        waitsForOtherFreshWorker: false
      """)

    return TuringQwenRenderedCodebookSegment(
      runID: materialized.runID,
      instanceID: materialized.instanceID,
      segmentIndex:
        materialized.segmentIndex,
      voiceID: materialized.voiceID,
      referenceCodes:
        materialized.referenceCodes,
      generatedCodes:
        materialized.generatedCodes,
      referenceRowCount:
        materialized.referenceRowCount,
      generatedRowCount:
        materialized.generatedRowCount,
      codebookCount:
        materialized.codebookCount,
      reachedEOS: materialized.reachedEOS,
      performanceMode:
        materialized.performanceMode,
      renderMetrics:
        materialized.renderMetrics,
      releaseToken: releaseToken
    )
  }

  public func unload() async {
    TuringQwenNativeDiagnostics.recordBreadcrumb(
      "freshInstance.unload.started",
      instanceID: id.rawValue
    )
    await baseCloneEngine?
      .releaseResidentState(
        reason:
          "\(id.rawValue).unload",
        logMemorySnapshot: false
      )

    baseCloneEngine = nil
    residentResources = nil

    TuringQwenNativeMemoryControl
      .clearCache(
        label:
          "freshInstance.\(id.rawValue).unload",
        shouldLogSnapshot: false
      )
    TuringQwenNativeDiagnostics.recordBreadcrumb(
      "freshInstance.unload.completed",
      instanceID: id.rawValue
    )
  }
}
