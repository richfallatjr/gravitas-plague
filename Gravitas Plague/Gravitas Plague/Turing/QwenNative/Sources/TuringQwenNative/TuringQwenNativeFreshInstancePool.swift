import Foundation
import MLX

public actor TuringQwenNativeFreshInstancePool {
    public static let defaultInstanceCount = 2

    private struct SharedRecoveryUnloadResult {
        let lanes: [TuringQwenNativeLaneReleaseReceipt]
        let shared: TuringQwenNativeSharedResidencyReleaseReceipt?
    }

    public private(set) var requestedInstanceCount: Int
    public private(set) var actualInstanceCount: Int = 0
    public let fallbackAllowed: Bool
    public let memoryGate: TuringQwenNativeFreshInstanceMemoryGate
    public let residencyMode: TuringQwenNativeResidencyMode
    public nonisolated let poolID: UUID
    public nonisolated let recoverySessionID: UUID
    public nonisolated let recoveryRunID: String
    public nonisolated let recoveryGeneration: TuringQwenNativeRecoveryGeneration
    public nonisolated let baselineMLXActiveBytes: UInt64

    private var instances: [TuringQwenNativeFreshInstance] = []
    private var availableInstanceIDs: [TuringQwenNativeFreshInstanceID] = []
    private var sharedResidencyOwner: TuringQwenNativeSharedResidencyOwner?
    private var sharedResidencyToken: TuringQwenNativeSharedResidencyOwner.Token?
    private var readyOwnershipReport: TuringQwenNativeResidencyOwnershipReport?
    private var runMetrics = TuringQwenNativeResidencyRunMetrics()
    private var sharedCloneReferenceRowCount: Int?
    private var residencySamples: [TuringQwenNativeResidencyMemorySample] = []
    #if GR_TURING_QUALIFICATION
    private var sharedWeightQualificationBaseline:
        TuringQwenNativeSharedWeightQualificationSnapshot?
    #endif

    public init(
        requestedInstanceCount: Int = TuringQwenNativeFreshInstancePool.defaultInstanceCount,
        fallbackAllowed: Bool = false,
        memoryGate: TuringQwenNativeFreshInstanceMemoryGate = .init(),
        residencyMode: TuringQwenNativeResidencyMode = .independentFresh2,
        sharedResidencyOwner: TuringQwenNativeSharedResidencyOwner? = nil,
        recoverySessionID: UUID = UUID(),
        recoveryRunID: String = "unregistered",
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial
    ) throws {
        guard fallbackAllowed == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh2 does not permit a reduced-lane fallback."
            )
        }
        if residencyMode.isShippingTopology {
            guard requestedInstanceCount == 2 else {
                throw TuringQwenNativeError.invalidConfig(
                    "Shipping Fresh2 residency modes require exactly two instances."
                )
            }
        } else {
            #if !GR_TURING_QUALIFICATION
            throw TuringQwenNativeError.invalidConfig(
                "Single-lane shared control requires GR_TURING_QUALIFICATION."
            )
            #else
            guard requestedInstanceCount == 1 else {
                throw TuringQwenNativeError.invalidConfig(
                    "Single-lane shared control requires exactly one instance."
                )
            }
            #endif
        }
        self.requestedInstanceCount = requestedInstanceCount
        self.fallbackAllowed = fallbackAllowed
        self.memoryGate = memoryGate
        self.residencyMode = residencyMode
        self.sharedResidencyOwner = sharedResidencyOwner
        self.poolID = UUID()
        self.recoverySessionID = recoverySessionID
        self.recoveryRunID = recoveryRunID
        self.recoveryGeneration = recoveryGeneration
        self.baselineMLXActiveBytes = UInt64(
            max(0, Memory.snapshot().activeMemory)
        )
    }

    public func warmLoadExactlyRequestedInstances(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        guard instances.isEmpty, actualInstanceCount == 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh residency pool is already warm-loaded."
            )
        }
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.mode.selected",
            details: [
                "residencyMode": residencyMode.rawValue,
                "requestedInstanceCount": String(requestedInstanceCount),
                "fallbackAllowed": String(fallbackAllowed)
            ]
        )
        print("""
        [TuringQwenFresh2] pool warm load started
          requestedInstanceCount: \(requestedInstanceCount)
          residencyMode: \(residencyMode.rawValue)
          sharedWeights: \(residencyMode != .independentFresh2)
          fallbackAllowed: false
        """)

        do {
            switch residencyMode {
            case .independentFresh2:
                try await warmLoadIndependent(
                    modelRoot: modelRoot,
                    cloneProfile: cloneProfile,
                    variantID: variantID,
                    performanceMode: performanceMode
                )
            case .sharedImmutableFresh2, .singleLaneSharedControl:
                try await warmLoadShared(
                    modelRoot: modelRoot,
                    cloneProfile: cloneProfile,
                    variantID: variantID,
                    performanceMode: performanceMode
                )
            }
        } catch {
            if let failure = error as? TuringQwenNativeMetalFailure {
                await TuringQwenNativeMetalCircuitBreaker.shared.trip(
                    failure,
                    generation: recoveryGeneration
                )
                let receipt = await unloadForRecovery(
                    reason: "warmLoadMetalFailure",
                    schedulerEvidence: .init(
                        decoderReceipt: .notStarted(
                            runID: recoveryRunID,
                            generation: recoveryGeneration
                        ),
                        admissionReceipt: .notStarted(
                            generation: recoveryGeneration
                        ),
                        queueCancelled: true,
                        releaseLedgerCleared: true
                    )
                )
                await TuringQwenNativeMetalCircuitBreaker.shared
                    .beginAfterOwnershipRelease(
                        receipt: receipt,
                        baselineActiveBytes: baselineMLXActiveBytes
                    )
            }
            throw error
        }
    }

    public func warmedInstancesExactlyRequestedCount() throws -> [TuringQwenNativeFreshInstance] {
        guard instances.count == requestedInstanceCount else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Fresh Qwen requires \(requestedInstanceCount) warm instances; found \(instances.count)."
            )
        }
        return instances
    }

    public func checkout() throws -> TuringQwenNativeFreshInstance {
        guard let id = availableInstanceIDs.first,
              let instance = instances.first(where: { $0.id == id }) else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "No fresh Qwen instance is available for checkout."
            )
        }
        availableInstanceIDs.removeFirst()
        return instance
    }

    public func checkin(_ instance: TuringQwenNativeFreshInstance) {
        let id = instance.id
        guard availableInstanceIDs.contains(id) == false else { return }
        availableInstanceIDs.append(id)
    }

    public func residencyOwnershipReport() throws -> TuringQwenNativeResidencyOwnershipReport {
        guard let readyOwnershipReport else {
            throw TuringQwenNativeError.invalidConfig(
                "Fresh residency ownership report is unavailable before warm load."
            )
        }
        return readyOwnershipReport
    }

    public func residencyRunMetrics() -> TuringQwenNativeResidencyRunMetrics {
        runMetrics
    }

    public func recordResidencyMemoryBoundary(_ label: String) {
        if label.contains("first"), residencySamples.contains(where: { $0.label == label }) {
            return
        }
        appendResidencySample(label: label, snapshot: .capture())
    }

    public func recordResidencyPeakBoundary() {
        guard residencySamples.contains(where: { $0.label == "run.peak" }) == false,
              let peak = peakResidencyMemory() else { return }
        appendResidencySample(label: "run.peak", snapshot: peak)
    }

    public func residencySnapshotsForDiagnostics() async throws ->
        [TuringQwenNativeFreshInstanceResidencySnapshot]
    {
        try await residencySnapshots(for: instances)
    }

    public func preparedSharedCloneReferenceRowCount() throws -> Int {
        guard residencyMode != .independentFresh2,
              let sharedCloneReferenceRowCount else {
            throw TuringQwenNativeError.invalidConfig(
                "A shared clone reference-row count is unavailable in this residency mode."
            )
        }
        return sharedCloneReferenceRowCount
    }

    #if GR_TURING_QUALIFICATION
    public func verifySharedWeightsUnchangedAfterQualificationRun() async throws {
        guard residencyMode != .independentFresh2 else { return }
        guard let owner = sharedResidencyOwner,
              let token = sharedResidencyToken,
              let baseline = sharedWeightQualificationBaseline else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared weight qualification baseline is unavailable."
            )
        }
        let after = try await owner.captureSharedWeightQualificationSnapshot(
            token: token
        )
        guard after == baseline else {
            TuringQwenNativeDiagnostics.recordResidencyEvent(
                "qwen.residency.sharedWeightMutationDetected",
                ownerID: token.ownerID
            )
            throw TuringQwenNativeError.invalidConfig(
                "Shared Qwen weights changed during the two-lane qualification run."
            )
        }
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.sharedWeightGuardPassed",
            ownerID: token.ownerID,
            details: [
                "tensorCount": String(after.tensors.count),
                "samplesPerTensor": "4"
            ]
        )
    }
    #endif

    public func unloadAll(reason: String) async {
        switch residencyMode {
        case .independentFresh2:
            recordResidencyMemoryBoundary("pool.beforeLaneRelease")
            for instance in instances {
                await instance.unloadIndependent(reason: reason)
            }
            recordResidencyMemoryBoundary("pool.afterLaneRelease")
            recordResidencyMemoryBoundary("pool.afterFinalCacheClear")
            resetPoolCollections(preserveReport: true)
        case .sharedImmutableFresh2, .singleLaneSharedControl:
            await unloadShared(reason: reason)
        }
        print("""
        [TuringQwenFresh2] pool unloaded
          reason: \(reason)
          residencyMode: \(residencyMode.rawValue)
          fallbackUsed: false
        """)
    }

    public func unloadForRecovery(
        reason: String,
        schedulerEvidence: TuringQwenNativeRecoverySchedulerEvidence
    ) async -> TuringQwenNativeRecoveryReleaseReceipt {
        let releasingInstances = instances
        var snapshots: [
            String: TuringQwenNativeFreshInstanceResidencySnapshot
        ] = [:]
        for instance in releasingInstances {
            snapshots[instance.id.rawValue] =
                try? await instance.residencySnapshot()
        }
        var laneReceipts: [TuringQwenNativeLaneReleaseReceipt] = []
        var sharedReceipt: TuringQwenNativeSharedResidencyReleaseReceipt?

        switch residencyMode {
        case .independentFresh2:
            for instance in releasingInstances {
                await instance.unloadIndependent(
                    reason: reason,
                    clearProcessCache: false
                )
                let state = await instance.recoveryReleaseState()
                laneReceipts.append(
                    makeLaneRecoveryReceipt(
                        instanceID: instance.id.rawValue,
                        snapshot: snapshots[instance.id.rawValue],
                        state: state,
                        residencyReleased: state.complete
                    )
                )
            }
            resetPoolCollections(preserveReport: true)
        case .sharedImmutableFresh2, .singleLaneSharedControl:
            let result = await unloadSharedForRecovery(
                instances: releasingInstances,
                snapshots: snapshots,
                reason: reason
            )
            laneReceipts = result.lanes
            sharedReceipt = result.shared
        }

        if laneReceipts.isEmpty {
            laneReceipts = (0..<requestedInstanceCount).map { index in
                TuringQwenNativeLaneReleaseReceipt(
                    instanceID: "fresh-\(index)",
                    generation: recoveryGeneration,
                    mutableStateID: nil,
                    residentResourceID: nil,
                    weightStoreID: nil,
                    sharedOwnerID: nil,
                    engineReleased: true,
                    mutableStateReleased: true,
                    residencyReleased: true,
                    activeRenderCount: 0
                )
            }
        }

        TuringQwenNativeMemoryControl.clearCache(
            label: "metalRecovery.finalOwnershipReconciliation.\(reason)",
            shouldLogSnapshot: true
        )
        let memory = Memory.snapshot()
        return .init(
            sessionID: recoverySessionID,
            runID: recoveryRunID,
            generation: recoveryGeneration,
            poolID: poolID,
            laneReceipts: laneReceipts,
            decoderReceipt: schedulerEvidence.decoderReceipt,
            admissionReceipt: schedulerEvidence.admissionReceipt,
            sharedResidencyReceipt: sharedReceipt,
            queueCancelled: schedulerEvidence.queueCancelled,
            releaseLedgerCleared: schedulerEvidence.releaseLedgerCleared,
            MLXActiveBytesAfterRelease: UInt64(max(0, memory.activeMemory)),
            MLXCacheBytesAfterRelease: UInt64(max(0, memory.cacheMemory))
        )
    }

    private func warmLoadIndependent(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        let started = Date()
        recordResidencyMemoryBoundary("pool.beforeResidencyOwner")
        var loaded: [TuringQwenNativeFreshInstance] = []
        var engineSeconds: [Double] = []
        do {
            for index in 0..<requestedInstanceCount {
                let id = TuringQwenNativeFreshInstanceID(index: index)
                try requireMemoryGateAllows(id, createdCount: loaded.count)
                recordResidencyMemoryBoundary("lane\(index).beforeEngine")
                let engineStart = Date()
                let instance = TuringQwenNativeFreshInstance(
                    id: id,
                    recoveryGeneration: recoveryGeneration
                )
                try await instance.warmLoadIndependent(
                    modelRoot: modelRoot,
                    cloneProfile: cloneProfile,
                    variantID: variantID,
                    performanceMode: performanceMode
                )
                engineSeconds.append(Date().timeIntervalSince(engineStart))
                loaded.append(instance)
                recordResidencyMemoryBoundary("lane\(index).afterEngine")
            }
        } catch {
            for instance in loaded {
                await instance.unloadIndependent(reason: "independentWarmLoadRollback")
            }
            resetPoolCollections()
            throw error
        }
        instances = loaded
        actualInstanceCount = loaded.count
        availableInstanceIDs = loaded.map(\.id)
        let snapshots = try await residencySnapshots(for: loaded)
        readyOwnershipReport = Self.makeOwnershipReport(
            mode: .independentFresh2,
            requested: requestedInstanceCount,
            snapshots: snapshots,
            activeLeaseCount: 0
        )
        runMetrics = .init(
            ownerLoadSeconds: engineSeconds.reduce(0, +),
            laneEngineCreationSeconds: engineSeconds,
            sessionReadySeconds: Date().timeIntervalSince(started),
            peakMemory: peakResidencyMemory(),
            boundedSamples: residencySamples
        )
        recordResidencyMemoryBoundary("pool.ready")
        try TuringQwenNativeResidencyAudit.validate(readyOwnershipReport!)
        logReady(report: readyOwnershipReport!)
    }

    private func warmLoadShared(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        let sessionStart = Date()
        recordResidencyMemoryBoundary("pool.beforeResidencyOwner")
        let owner = sharedResidencyOwner ?? TuringQwenNativeSharedResidencyOwner()
        let ownerLoadStart = Date()
        let token: TuringQwenNativeSharedResidencyOwner.Token
        do {
            token = try await owner.prepare(
                modelRoot: modelRoot,
                cloneProfile: cloneProfile,
                variantID: variantID
            )
        } catch {
            TuringQwenNativeMemoryControl.clearCache(
                label: "sharedResidency.ownerLoadFailed",
                shouldLogSnapshot: true
            )
            throw error
        }
        let ownerLoadSeconds = Date().timeIntervalSince(ownerLoadStart)
        #if GR_TURING_QUALIFICATION
        do {
            sharedWeightQualificationBaseline = try await owner
                .captureSharedWeightQualificationSnapshot(token: token)
        } catch {
            _ = try? await owner.finish(
                token: token,
                reason: "sharedWeightQualificationBaselineFailed"
            )
            TuringQwenNativeMemoryControl.clearCache(
                label: "sharedResidency.qualificationBaselineFailed",
                shouldLogSnapshot: true
            )
            resetPoolCollections()
            throw error
        }
        #endif
        let loadMetrics = try await owner.residentResourceLoadMetrics(token: token)
        appendResidencySample(label: "owner.beforeConfig", snapshot: loadMetrics.before)
        appendResidencySample(label: "owner.afterConfig", snapshot: loadMetrics.afterConfig)
        appendResidencySample(label: "owner.afterWeightStore", snapshot: loadMetrics.afterWeightStore)
        appendResidencySample(label: "owner.afterTalkerWeights", snapshot: loadMetrics.afterTalkerWeights)
        appendResidencySample(label: "owner.afterCodePredictorWeights", snapshot: loadMetrics.afterCodePredictorWeights)
        appendResidencySample(label: "owner.afterCloneConditioning", snapshot: loadMetrics.ready)
        appendResidencySample(label: "owner.ready", snapshot: loadMetrics.ready)
        var loaded: [(TuringQwenNativeFreshInstance, TuringQwenNativeSharedResidencyLease)] = []
        var pendingLease: TuringQwenNativeSharedResidencyLease?
        var engineSeconds: [Double] = []

        do {
            for index in 0..<requestedInstanceCount {
                let id = TuringQwenNativeFreshInstanceID(index: index)
                try requireMemoryGateAllows(id, createdCount: loaded.count)
                recordResidencyMemoryBoundary("lane\(index).beforeEngine")
                let lease = try await owner.acquireLaneLease(
                    token: token,
                    laneInstanceID: id
                )
                pendingLease = lease
                let engineStart = Date()
                let instance = TuringQwenNativeFreshInstance(
                    id: id,
                    recoveryGeneration: recoveryGeneration
                )
                try await instance.warmLoadShared(
                    lease: lease,
                    cloneProfile: cloneProfile,
                    variantID: variantID,
                    performanceMode: performanceMode
                )
                engineSeconds.append(Date().timeIntervalSince(engineStart))
                loaded.append((instance, lease))
                recordResidencyMemoryBoundary("lane\(index).afterEngine")
                pendingLease = nil
            }

            let loadedInstances = loaded.map(\.0)
            let snapshots = try await Self.validateSharedPool(
                instances: loadedInstances,
                expectedCount: requestedInstanceCount
            )
            let activeLeases = try await owner.activeLeaseCount(token: token)
            instances = loadedInstances
            actualInstanceCount = loadedInstances.count
            availableInstanceIDs = loadedInstances.map(\.id)
            sharedResidencyOwner = owner
            sharedResidencyToken = token
            sharedCloneReferenceRowCount = loaded[0].1.snapshot
                .cloneConditioning.conditioning.artifacts.referenceRowCount
            readyOwnershipReport = Self.makeOwnershipReport(
                mode: residencyMode,
                requested: requestedInstanceCount,
                snapshots: snapshots,
                activeLeaseCount: activeLeases
            )
            runMetrics = .init(
                ownerLoadSeconds: ownerLoadSeconds,
                laneEngineCreationSeconds: engineSeconds,
                sessionReadySeconds: Date().timeIntervalSince(sessionStart),
                peakMemory: peakResidencyMemory(),
                boundedSamples: residencySamples
            )
            recordResidencyMemoryBoundary("pool.ready")
            try TuringQwenNativeResidencyAudit.validate(readyOwnershipReport!)
            logReady(report: readyOwnershipReport!)
        } catch {
            if let pendingLease {
                try? await owner.releaseLaneLease(
                    pendingLease,
                    reason: "sharedWarmLoadRollback.pendingLease"
                )
            }
            pendingLease = nil
            for (instance, lease) in loaded.reversed() {
                _ = await instance.unloadLaneState(reason: "sharedWarmLoadRollback")
                try? await owner.releaseLaneLease(
                    lease,
                    reason: "sharedWarmLoadRollback.boundLease"
                )
            }
            loaded.removeAll(keepingCapacity: false)
            _ = try? await owner.finish(
                token: token,
                reason: "sharedWarmLoadFailed"
            )
            TuringQwenNativeMemoryControl.clearCache(
                label: "sharedResidency.warmLoadRollback",
                shouldLogSnapshot: true
            )
            resetPoolCollections()
            throw error
        }
    }

    private func unloadShared(reason: String) async {
        guard let owner = sharedResidencyOwner,
              let token = sharedResidencyToken else {
            resetPoolCollections()
            return
        }
        var receipts: [TuringQwenNativeFreshInstanceUnloadReceipt] = []
        recordResidencyMemoryBoundary("pool.beforeLaneRelease")
        for instance in instances {
            receipts.append(await instance.unloadLaneState(reason: reason))
        }
        recordResidencyMemoryBoundary("pool.afterLaneRelease")
        for receipt in receipts {
            guard let lease = receipt.sharedLease else { continue }
            do {
                try await owner.releaseLaneLease(lease, reason: reason)
            } catch {
                TuringQwenNativeDiagnostics.recordResidencyEvent(
                    "qwen.residency.invariantViolation",
                    ownerID: token.ownerID,
                    instanceID: receipt.instanceID.rawValue,
                    details: ["error": error.localizedDescription]
                )
            }
        }
        receipts.removeAll(keepingCapacity: false)
        recordResidencyMemoryBoundary("owner.beforeRelease")
        let finish = try? await owner.finish(token: token, reason: reason)
        recordResidencyMemoryBoundary("owner.afterRelease")
        let immediatePostOwnerRelease = residencySamples.last {
            $0.label == "owner.afterRelease"
        }?.snapshot
        sharedResidencyOwner = nil
        sharedResidencyToken = nil
        sharedCloneReferenceRowCount = nil
        #if GR_TURING_QUALIFICATION
        sharedWeightQualificationBaseline = nil
        #endif
        if let report = readyOwnershipReport {
            readyOwnershipReport = TuringQwenNativeResidencyOwnershipReport(
                mode: report.mode,
                requestedLaneCount: report.requestedLaneCount,
                actualLaneCount: report.actualLaneCount,
                uniqueResidentResourceCount: report.uniqueResidentResourceCount,
                uniqueWeightStoreCount: report.uniqueWeightStoreCount,
                uniqueCloneConditioningCount: report.uniqueCloneConditioningCount,
                laneEngineCount: report.laneEngineCount,
                uniqueLaneMutableStateCount: report.uniqueLaneMutableStateCount,
                uniqueStaticPromptCacheCount: report.uniqueStaticPromptCacheCount,
                uniqueTalkerKVCacheOwnerCount: report.uniqueTalkerKVCacheOwnerCount,
                uniqueCodePredictorKVCacheOwnerCount: report.uniqueCodePredictorKVCacheOwnerCount,
                uniqueSamplerStateOwnerCount: report.uniqueSamplerStateOwnerCount,
                activeLeaseCountAtReady: report.activeLeaseCountAtReady,
                activeLeaseCountAtFinish: finish?.activeLeaseCountAtFinish ?? -1,
                decoderSessionCount: report.decoderSessionCount,
                fallbackUsed: report.fallbackUsed
            )
        }
        resetPoolCollections(preserveReport: true)
        TuringQwenNativeMemoryControl.clearCache(
            label: "sharedResidency.ownerReleased.\(reason)",
            shouldLogSnapshot: true
        )
        recordResidencyMemoryBoundary("pool.afterFinalCacheClear")
        runMetrics = .init(
            ownerLoadSeconds: runMetrics.ownerLoadSeconds,
            laneEngineCreationSeconds: runMetrics.laneEngineCreationSeconds,
            sessionReadySeconds: runMetrics.sessionReadySeconds,
            firstRenderMemoryByLane: runMetrics.firstRenderMemoryByLane,
            peakMemory: peakResidencyMemory(),
            immediatePostOwnerReleaseMemory: immediatePostOwnerRelease,
            boundedSamples: residencySamples
        )
    }

    private func unloadSharedForRecovery(
        instances releasingInstances: [TuringQwenNativeFreshInstance],
        snapshots: [String: TuringQwenNativeFreshInstanceResidencySnapshot],
        reason: String
    ) async -> SharedRecoveryUnloadResult {
        guard let owner = sharedResidencyOwner,
              let token = sharedResidencyToken else {
            var lanes: [TuringQwenNativeLaneReleaseReceipt] = []
            for instance in releasingInstances {
                _ = await instance.unloadLaneState(reason: reason)
                let state = await instance.recoveryReleaseState()
                lanes.append(
                    makeLaneRecoveryReceipt(
                        instanceID: instance.id.rawValue,
                        snapshot: snapshots[instance.id.rawValue],
                        state: state,
                        residencyReleased: false
                    )
                )
            }
            resetPoolCollections(preserveReport: true)
            return .init(lanes: lanes, shared: nil)
        }

        var rawReceipts: [TuringQwenNativeFreshInstanceUnloadReceipt] = []
        for instance in releasingInstances {
            rawReceipts.append(
                await instance.unloadLaneState(reason: reason)
            )
        }

        var releasedInstanceIDs = Set<String>()
        for receipt in rawReceipts {
            guard let lease = receipt.sharedLease else { continue }
            do {
                try await owner.releaseLaneLease(lease, reason: reason)
                releasedInstanceIDs.insert(receipt.instanceID.rawValue)
            } catch {
                TuringQwenNativeDiagnostics.recordResidencyEvent(
                    "qwen.recovery.sharedLeaseReleaseFailed",
                    ownerID: token.ownerID,
                    instanceID: receipt.instanceID.rawValue,
                    details: ["error": error.localizedDescription]
                )
            }
        }
        let finish = try? await owner.finish(token: token, reason: reason)

        var lanes: [TuringQwenNativeLaneReleaseReceipt] = []
        for instance in releasingInstances {
            let state = await instance.recoveryReleaseState()
            lanes.append(
                makeLaneRecoveryReceipt(
                    instanceID: instance.id.rawValue,
                    snapshot: snapshots[instance.id.rawValue],
                    state: state,
                    residencyReleased:
                        releasedInstanceIDs.contains(instance.id.rawValue) &&
                        finish != nil
                )
            )
        }

        sharedResidencyOwner = nil
        sharedResidencyToken = nil
        sharedCloneReferenceRowCount = nil
        #if GR_TURING_QUALIFICATION
        sharedWeightQualificationBaseline = nil
        #endif
        resetPoolCollections(preserveReport: true)

        return .init(
            lanes: lanes,
            shared: .init(
                ownerID: token.ownerID,
                ownerGeneration: token.generation,
                releasedLeaseCount: releasedInstanceIDs.count,
                activeLeaseCountAfterRelease:
                    finish?.activeLeaseCountAtFinish ?? -1,
                ownerReleased: finish != nil
            )
        )
    }

    private func makeLaneRecoveryReceipt(
        instanceID: String,
        snapshot: TuringQwenNativeFreshInstanceResidencySnapshot?,
        state: (complete: Bool, activeRenders: Int),
        residencyReleased: Bool
    ) -> TuringQwenNativeLaneReleaseReceipt {
        .init(
            instanceID: instanceID,
            generation: recoveryGeneration,
            mutableStateID:
                snapshot?.laneMutableStateIdentity.mutableStateID,
            residentResourceID: snapshot?.residentResourceID,
            weightStoreID: snapshot?.weightStoreID,
            sharedOwnerID: snapshot?.ownerID,
            engineReleased: state.complete,
            mutableStateReleased: state.complete,
            residencyReleased: residencyReleased,
            activeRenderCount: state.activeRenders
        )
    }

    private func requireMemoryGateAllows(
        _ id: TuringQwenNativeFreshInstanceID,
        createdCount: Int
    ) throws {
        let decision = memoryGate.evaluateBeforeWarmLoad(instanceID: id)
        guard decision.allowed else {
            print("""
            [TuringQwenFresh2] failed
              reason: insufficientMemoryForFreshInstances
              residencyMode: \(residencyMode.rawValue)
              requestedInstanceCount: \(requestedInstanceCount)
              createdInstanceCount: \(createdCount)
              failedInstanceID: \(id.rawValue)
              activeMB: \(String(format: "%.1f", decision.activeMB))
              cacheMB: \(String(format: "%.1f", decision.cacheMB))
              fallbackUsed: false
            """)
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Insufficient memory for \(requestedInstanceCount) Fresh Qwen instances."
            )
        }
    }

    private func residencySnapshots(
        for loaded: [TuringQwenNativeFreshInstance]
    ) async throws -> [TuringQwenNativeFreshInstanceResidencySnapshot] {
        var snapshots: [TuringQwenNativeFreshInstanceResidencySnapshot] = []
        for instance in loaded {
            snapshots.append(try await instance.residencySnapshot())
        }
        return snapshots
    }

    static func validateSharedPool(
        instances: [TuringQwenNativeFreshInstance],
        expectedCount: Int = 2
    ) async throws -> [TuringQwenNativeFreshInstanceResidencySnapshot] {
        guard instances.count == expectedCount else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency expected \(expectedCount) Fresh lane engines."
            )
        }
        var snapshots: [TuringQwenNativeFreshInstanceResidencySnapshot] = []
        for instance in instances {
            snapshots.append(try await instance.residencySnapshot())
        }
        func requireUnique<Value: Hashable>(
            _ values: [Value],
            count: Int,
            label: String
        ) throws {
            guard Set(values).count == count else {
                throw TuringQwenNativeError.invalidConfig(
                    "Shared residency invariant failed for \(label)."
                )
            }
        }
        try requireUnique(snapshots.map(\.residentResourceID), count: 1, label: "resident resources")
        try requireUnique(snapshots.map(\.weightStoreID), count: 1, label: "weight stores")
        try requireUnique(snapshots.compactMap(\.cloneConditioningID), count: 1, label: "clone conditioning")
        try requireUnique(snapshots.compactMap(\.ownerID), count: 1, label: "owner IDs")
        try requireUnique(snapshots.compactMap(\.ownerGeneration), count: 1, label: "owner generations")
        try requireUnique(snapshots.map { $0.laneMutableStateIdentity.engineID }, count: expectedCount, label: "engine IDs")
        try requireUnique(snapshots.map { $0.laneMutableStateIdentity.mutableStateID }, count: expectedCount, label: "mutable state IDs")
        try requireUnique(snapshots.map { $0.laneMutableStateIdentity.staticPromptCacheID }, count: expectedCount, label: "static prompt caches")
        try requireUnique(snapshots.map { $0.laneMutableStateIdentity.talkerKVCacheOwnerID }, count: expectedCount, label: "talker KV owners")
        try requireUnique(snapshots.map { $0.laneMutableStateIdentity.codePredictorKVCacheOwnerID }, count: expectedCount, label: "code predictor KV owners")
        try requireUnique(snapshots.map { $0.laneMutableStateIdentity.samplerStateOwnerID }, count: expectedCount, label: "sampler owners")
        return snapshots
    }

    private static func makeOwnershipReport(
        mode: TuringQwenNativeResidencyMode,
        requested: Int,
        snapshots: [TuringQwenNativeFreshInstanceResidencySnapshot],
        activeLeaseCount: Int
    ) -> TuringQwenNativeResidencyOwnershipReport {
        .init(
            mode: mode,
            requestedLaneCount: requested,
            actualLaneCount: snapshots.count,
            uniqueResidentResourceCount: Set(snapshots.map(\.residentResourceID)).count,
            uniqueWeightStoreCount: Set(snapshots.map(\.weightStoreID)).count,
            uniqueCloneConditioningCount: Set(snapshots.compactMap(\.cloneConditioningID)).count,
            laneEngineCount: snapshots.count,
            uniqueLaneMutableStateCount: Set(snapshots.map { $0.laneMutableStateIdentity.mutableStateID }).count,
            uniqueStaticPromptCacheCount: Set(snapshots.map { $0.laneMutableStateIdentity.staticPromptCacheID }).count,
            uniqueTalkerKVCacheOwnerCount: Set(snapshots.map { $0.laneMutableStateIdentity.talkerKVCacheOwnerID }).count,
            uniqueCodePredictorKVCacheOwnerCount: Set(snapshots.map { $0.laneMutableStateIdentity.codePredictorKVCacheOwnerID }).count,
            uniqueSamplerStateOwnerCount: Set(snapshots.map { $0.laneMutableStateIdentity.samplerStateOwnerID }).count,
            activeLeaseCountAtReady: activeLeaseCount,
            activeLeaseCountAtFinish: activeLeaseCount,
            decoderSessionCount: 1,
            fallbackUsed: false
        )
    }

    private func logReady(report: TuringQwenNativeResidencyOwnershipReport) {
        print("""
        [TuringQwenFresh2] pool ready
          residencyMode: \(report.mode.rawValue)
          requestedInstanceCount: \(report.requestedLaneCount)
          actualInstanceCount: \(report.actualLaneCount)
          uniqueResidentResources: \(report.uniqueResidentResourceCount)
          uniqueWeightStores: \(report.uniqueWeightStoreCount)
          uniqueCloneConditionings: \(report.uniqueCloneConditioningCount)
          laneEngineCount: \(report.laneEngineCount)
          sharedWeights: \(report.mode != .independentFresh2)
          fallbackUsed: false
        """)
    }

    private func resetPoolCollections(preserveReport: Bool = false) {
        instances.removeAll(keepingCapacity: false)
        availableInstanceIDs.removeAll(keepingCapacity: false)
        actualInstanceCount = 0
        if preserveReport == false {
            readyOwnershipReport = nil
            runMetrics = .init()
            sharedCloneReferenceRowCount = nil
            #if GR_TURING_QUALIFICATION
            sharedWeightQualificationBaseline = nil
            #endif
            residencySamples.removeAll(keepingCapacity: false)
        }
    }

    private func appendResidencySample(
        label: String,
        snapshot: TuringQwenNativeResidencyMemorySnapshot
    ) {
        guard residencySamples.count < 64 else { return }
        residencySamples.append(.init(label: label, snapshot: snapshot))
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.memory.sample",
            details: [
                "residencyMode": residencyMode.rawValue,
                "label": label,
                "physicalFootprintMB": String(format: "%.1f", snapshot.physicalFootprintMB),
                "residentSizeMB": String(format: "%.1f", snapshot.residentSizeMB),
                "availableProcessMemoryMB": String(format: "%.1f", snapshot.availableProcessMemoryMB),
                "mlxActiveMB": String(format: "%.1f", snapshot.MLXActiveMB),
                "mlxCacheMB": String(format: "%.1f", snapshot.MLXCacheMB)
            ]
        )
        var firstByLane = runMetrics.firstRenderMemoryByLane
        if label == "lane0.firstRenderStarted" {
            firstByLane["fresh-0"] = snapshot
        } else if label == "lane1.firstRenderStarted" {
            firstByLane["fresh-1"] = snapshot
        }
        runMetrics = .init(
            ownerLoadSeconds: runMetrics.ownerLoadSeconds,
            laneEngineCreationSeconds: runMetrics.laneEngineCreationSeconds,
            sessionReadySeconds: runMetrics.sessionReadySeconds,
            firstRenderMemoryByLane: firstByLane,
            peakMemory: peakResidencyMemory(),
            immediatePostOwnerReleaseMemory: runMetrics.immediatePostOwnerReleaseMemory,
            quiescentPostUnloadMemory: runMetrics.quiescentPostUnloadMemory,
            boundedSamples: residencySamples
        )
    }

    private func peakResidencyMemory() -> TuringQwenNativeResidencyMemorySnapshot? {
        residencySamples.max {
            $0.snapshot.physicalFootprintMB < $1.snapshot.physicalFootprintMB
        }?.snapshot
    }
}
