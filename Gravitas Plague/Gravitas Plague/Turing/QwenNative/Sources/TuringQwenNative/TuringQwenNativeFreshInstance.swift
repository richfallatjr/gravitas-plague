import Foundation

public struct TuringQwenNativeFreshInstanceResidencySnapshot:
    Sendable,
    Equatable,
    Codable
{
    public let instanceID: String
    public let residencyMode: TuringQwenNativeResidencyMode
    public let residentResourceID: UUID
    public let weightStoreID: UUID
    public let cloneConditioningID: UUID?
    public let ownerID: UUID?
    public let ownerGeneration: UInt64?
    public let laneMutableStateIdentity: TuringQwenNativeLaneMutableStateIdentity
}

public struct TuringQwenNativeFreshInstanceUnloadReceipt: @unchecked Sendable {
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let mode: TuringQwenNativeResidencyMode
    public let laneMutableStateIdentity: TuringQwenNativeLaneMutableStateIdentity?
    public let sharedLease: TuringQwenNativeSharedResidencyLease?
    public let mutableStateReleased: Bool
}

public actor TuringQwenNativeFreshInstance {
    private enum Binding {
        case independent(resources: TuringQwenNativeResidentResources)
        case shared(lease: TuringQwenNativeSharedResidencyLease)
    }

    public nonisolated let id: TuringQwenNativeFreshInstanceID
    public nonisolated let recoveryGeneration:
        TuringQwenNativeRecoveryGeneration
    private var binding: Binding?
    private var baseCloneEngine: TuringQwenNativeBaseCloneEngine?
    private var activeRenderCount = 0

    public init(
        id: TuringQwenNativeFreshInstanceID,
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial
    ) {
        self.id = id
        self.recoveryGeneration = recoveryGeneration
    }

    @available(
        *,
        deprecated,
        message: "Use warmLoadIndependent or warmLoadShared explicitly."
    )
    public func warmLoad(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        try await warmLoadIndependent(
            modelRoot: modelRoot,
            cloneProfile: cloneProfile,
            variantID: variantID,
            performanceMode: performanceMode
        )
    }

    public func warmLoadIndependent(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        guard binding == nil, baseCloneEngine == nil else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh instance is already warm-loaded."
            )
        }
        try await TuringQwenNativeMetalCircuitBreaker.shared.requireHealthy()
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "freshInstance.warmLoad.started",
            instanceID: id.rawValue,
            details: [
                "residencyMode": TuringQwenNativeResidencyMode.independentFresh2.rawValue,
                "voiceID": cloneProfile.voiceID,
                "variantID": variantID
            ]
        )
        let warmContext = TuringQwenNativeMLXExecutionContext(
            runID: "warmLoad.\(variantID)",
            instanceID: id,
            phase: .warmLoad,
            stage: "freshInstance.independentResourcesAndEngine"
        )
        let (resources, engine) = try TuringQwenNativeMLXErrorBoundary.run(
            context: warmContext
        ) {
            let resources = try TuringQwenNativeResidentResources(modelRoot: modelRoot)
            let engine = try TuringQwenNativeBaseCloneEngine(
                modelRoot: modelRoot,
                ownedResidentResources: resources,
                laneInstanceID: id,
                trace: .stdout(prefix: "[TuringQwenFresh2.\(id.rawValue)]")
            )
            return (resources, engine)
        }
        binding = .independent(resources: resources)
        baseCloneEngine = engine
        recordEngineCreated(
            mode: .independentFresh2,
            engine: engine,
            ownerID: nil,
            performanceMode: performanceMode
        )
    }

    public func warmLoadShared(
        lease: TuringQwenNativeSharedResidencyLease,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        guard binding == nil, baseCloneEngine == nil else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh instance is already warm-loaded."
            )
        }
        guard lease.laneInstanceID == id else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency lease belongs to a different Fresh instance."
            )
        }
        let identity = lease.snapshot.identity
        guard identity.voiceID == cloneProfile.voiceID,
              identity.variantID == variantID,
              identity.modelID == cloneProfile.modelID else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh lane request does not match shared residency identity."
            )
        }
        let engine = try TuringQwenNativeBaseCloneEngine(
            sharedResidencyLease: lease,
            trace: .stdout(prefix: "[TuringQwenFresh2.\(id.rawValue)]")
        )
        binding = .shared(lease: lease)
        baseCloneEngine = engine
        recordEngineCreated(
            mode: .sharedImmutableFresh2,
            engine: engine,
            ownerID: identity.ownerID,
            performanceMode: performanceMode
        )
    }

    public func renderCodebookAndRelease(
        _ request: TuringQwenNativeBaseCloneSegmentRequest,
        runID: String,
        laneIndex: Int? = nil,
        releaseLedger: TuringQwenRenderReleaseLedger
    ) async throws -> TuringQwenRenderedCodebookSegment {
        guard let binding, let engine = baseCloneEngine else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Fresh Qwen instance \(id.rawValue) is not warm-loaded."
            )
        }
        if case .shared(let lease) = binding {
            let identity = lease.snapshot.identity
            guard lease.ownerToken.ownerID == identity.ownerID,
                  lease.ownerToken.generation == identity.generation,
                  lease.laneInstanceID == id,
                  request.cloneProfile.voiceID == identity.voiceID,
                  request.cloneProfile.defaultVariantID == identity.variantID,
                  request.cloneProfile.modelID == identity.modelID else {
                throw TuringQwenNativeError.invalidConfig(
                    "Shared Fresh lane render request does not match its owner lease."
                )
            }
        }

        activeRenderCount += 1
        defer { activeRenderCount -= 1 }

        let residencyDiagnostic = try residencySnapshot()
        let materialized = try await TuringQwenNativeMLXErrorBoundary.run(
            context: TuringQwenNativeMLXExecutionContext(
                runID: runID,
                instanceID: id,
                segmentIndex: request.segmentIndex,
                laneIndex: laneIndex,
                phase: .dynamicTalker,
                stage: "baseClone.renderAndMaterialize",
                residencyOwnerID: residencyDiagnostic.ownerID?.uuidString,
                weightStoreID: residencyDiagnostic.weightStoreID.uuidString,
                laneMutableStateID: residencyDiagnostic.laneMutableStateIdentity.mutableStateID.uuidString
            )
        ) {
            try await engine.materializeRenderedSegmentAndRelease(
                request: request,
                runID: runID,
                instanceID: id,
                laneIndex: laneIndex
            )
        }

        let releaseToken = TuringQwenRenderReleaseToken(
            runID: runID,
            segmentIndex: request.segmentIndex,
            instanceID: id,
            recoveryGeneration: recoveryGeneration
        )
        await releaseLedger.record(releaseToken)
        print("""
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
            segmentIndex: materialized.segmentIndex,
            voiceID: materialized.voiceID,
            referenceCodes: materialized.referenceCodes,
            generatedCodes: materialized.generatedCodes,
            referenceRowCount: materialized.referenceRowCount,
            generatedRowCount: materialized.generatedRowCount,
            codebookCount: materialized.codebookCount,
            reachedEOS: materialized.reachedEOS,
            performanceMode: materialized.performanceMode,
            renderMetrics: materialized.renderMetrics,
            releaseToken: releaseToken
        )
    }

    public func residencySnapshot() throws -> TuringQwenNativeFreshInstanceResidencySnapshot {
        guard let binding, let engine = baseCloneEngine else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh instance is not warm-loaded for a residency snapshot."
            )
        }
        switch binding {
        case .independent(let resources):
            return .init(
                instanceID: id.rawValue,
                residencyMode: .independentFresh2,
                residentResourceID: resources.resourceID,
                weightStoreID: resources.weightsStore.identity,
                cloneConditioningID: nil,
                ownerID: nil,
                ownerGeneration: nil,
                laneMutableStateIdentity: engine.laneMutableStateIdentity
            )
        case .shared(let lease):
            return .init(
                instanceID: id.rawValue,
                residencyMode: .sharedImmutableFresh2,
                residentResourceID: lease.snapshot.modelResources.resourceID,
                weightStoreID: lease.snapshot.identity.weightStoreID,
                cloneConditioningID: lease.snapshot.identity.cloneConditioningID,
                ownerID: lease.snapshot.identity.ownerID,
                ownerGeneration: lease.snapshot.identity.generation,
                laneMutableStateIdentity: engine.laneMutableStateIdentity
            )
        }
    }

    public func unloadLaneState(
        reason: String
    ) async -> TuringQwenNativeFreshInstanceUnloadReceipt {
        let identity = baseCloneEngine?.laneMutableStateIdentity
        _ = await baseCloneEngine?.releaseLaneState(reason: "\(id.rawValue).\(reason)")
        baseCloneEngine = nil
        let receipt: TuringQwenNativeFreshInstanceUnloadReceipt
        switch binding {
        case .shared(let lease):
            receipt = .init(
                instanceID: id,
                mode: .sharedImmutableFresh2,
                laneMutableStateIdentity: identity,
                sharedLease: lease,
                mutableStateReleased: true
            )
        case .independent:
            receipt = .init(
                instanceID: id,
                mode: .independentFresh2,
                laneMutableStateIdentity: identity,
                sharedLease: nil,
                mutableStateReleased: true
            )
        case nil:
            receipt = .init(
                instanceID: id,
                mode: .independentFresh2,
                laneMutableStateIdentity: identity,
                sharedLease: nil,
                mutableStateReleased: true
            )
        }
        binding = nil
        return receipt
    }

    public func unloadIndependent(
        reason: String,
        clearProcessCache: Bool = true
    ) async {
        guard case .independent = binding else {
            _ = await unloadLaneState(reason: reason)
            return
        }
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "freshInstance.unload.started",
            instanceID: id.rawValue
        )
        await baseCloneEngine?.releaseResidentState(
            reason: "\(id.rawValue).\(reason)",
            logMemorySnapshot: false
        )
        baseCloneEngine = nil
        binding = nil
        if clearProcessCache {
            TuringQwenNativeMemoryControl.clearCache(
                label: "freshInstance.\(id.rawValue).unload",
                shouldLogSnapshot: false
            )
        }
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "freshInstance.unload.completed",
            instanceID: id.rawValue
        )
    }

    public func recoveryReleaseState() -> (complete: Bool, activeRenders: Int) {
        (
            complete: binding == nil && baseCloneEngine == nil,
            activeRenders: activeRenderCount
        )
    }

    @available(*, deprecated, message: "Use residency-mode-specific unload.")
    public func unload() async {
        await unloadIndependent(reason: "legacyUnload")
    }

    private nonisolated func recordEngineCreated(
        mode: TuringQwenNativeResidencyMode,
        engine: TuringQwenNativeBaseCloneEngine,
        ownerID: UUID?,
        performanceMode: TuringQwenNativePerformanceMode
    ) {
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.lane.engine.created",
            ownerID: ownerID,
            instanceID: id.rawValue,
            details: [
                "residencyMode": mode.rawValue,
                "engineID": engine.engineID.uuidString,
                "mutableStateID": engine.laneMutableStateIdentity.mutableStateID.uuidString,
                "performanceMode": performanceMode.rawValue
            ]
        )
    }
}
