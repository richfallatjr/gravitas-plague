import Foundation

public actor TuringQwenNativeSharedResidencyOwner {
    public struct Token: Sendable, Equatable, Hashable, Codable {
        public let ownerID: UUID
        public let generation: UInt64

        public init(ownerID: UUID, generation: UInt64) {
            self.ownerID = ownerID
            self.generation = generation
        }
    }

    private struct RequestIdentity: Sendable, Equatable {
        let modelRootPath: String
        let voiceID: String
        let variantID: String
    }

    private enum State {
        case idle
        case loading(
            token: Token,
            request: RequestIdentity,
            task: Task<TuringQwenNativeSharedResidencySnapshot, Error>
        )
        case ready(
            token: Token,
            request: RequestIdentity,
            snapshot: TuringQwenNativeSharedResidencySnapshot,
            leaseRegistry: TuringQwenNativeResidencyLeaseRegistry
        )
        case releasing(token: Token)
        case released(token: Token)
        case failed(token: Token, message: String)
    }

    private var generation: UInt64 = 0
    private var state: State = .idle
    private let loader: any TuringQwenNativeResidencyLoading

    public init(
        loader: any TuringQwenNativeResidencyLoading =
            TuringQwenNativeProductionResidencyLoader()
    ) {
        self.loader = loader
    }

    public func prepare(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String
    ) async throws -> Token {
        try await TuringQwenNativeMetalCircuitBreaker.shared.requireHealthy()
        let request = RequestIdentity(
            modelRootPath: modelRoot.standardizedFileURL.path,
            voiceID: cloneProfile.voiceID,
            variantID: variantID
        )

        switch state {
        case .idle, .released:
            break
        case .loading(let token, let activeRequest, let task):
            guard activeRequest == request else {
                throw TuringQwenNativeError.invalidConfig(
                    "Shared residency is already loading a different model or voice."
                )
            }
            do {
                let snapshot = try await task.value
                try publishReadyIfStillLoading(
                    token: token,
                    request: request,
                    snapshot: snapshot
                )
            } catch {
                state = .failed(token: token, message: error.localizedDescription)
                throw error
            }
            return token
        case .ready(let token, let activeRequest, _, _):
            guard activeRequest == request else {
                throw TuringQwenNativeError.invalidConfig(
                    "Shared residency is already prepared for a different model or voice."
                )
            }
            return token
        case .releasing:
            throw TuringQwenNativeError.invalidConfig("Shared residency is releasing.")
        case .failed(_, let message):
            throw TuringQwenNativeError.invalidConfig(message)
        }

        generation &+= 1
        let token = Token(ownerID: UUID(), generation: generation)
        let loader = self.loader
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.owner.load.started",
            ownerID: token.ownerID,
            details: [
                "generation": String(token.generation),
                "voiceID": cloneProfile.voiceID,
                "variantID": variantID
            ]
        )
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let snapshot = try autoreleasepool {
                try loader.load(
                    token: token,
                    modelRoot: modelRoot,
                    cloneProfile: cloneProfile,
                    variantID: variantID
                )
            }
            try Task.checkCancellation()
            return snapshot
        }
        state = .loading(token: token, request: request, task: task)

        do {
            let snapshot = try await task.value
            try publishReadyIfStillLoading(
                token: token,
                request: request,
                snapshot: snapshot
            )
            TuringQwenNativeDiagnostics.recordResidencyEvent(
                "qwen.residency.owner.load.completed",
                ownerID: token.ownerID,
                details: [
                    "resourceID": snapshot.modelResources.resourceID.uuidString,
                    "weightStoreID": snapshot.identity.weightStoreID.uuidString,
                    "cloneConditioningID": snapshot.identity.cloneConditioningID.uuidString
                ]
            )
            return token
        } catch {
            task.cancel()
            state = .failed(token: token, message: error.localizedDescription)
            TuringQwenNativeDiagnostics.recordResidencyEvent(
                "qwen.residency.owner.failed",
                ownerID: token.ownerID,
                details: ["error": error.localizedDescription]
            )
            throw error
        }
    }

    public func acquireLaneLease(
        token: Token,
        laneInstanceID: TuringQwenNativeFreshInstanceID
    ) throws -> TuringQwenNativeSharedResidencyLease {
        guard case .ready(
            let activeToken,
            let request,
            let snapshot,
            var leaseRegistry
        ) = state, activeToken == token else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency is not ready for this owner token."
            )
        }
        let leaseID = try leaseRegistry.acquire(laneInstanceID: laneInstanceID)
        let lease = TuringQwenNativeSharedResidencyLease(
            leaseID: leaseID,
            ownerToken: token,
            laneInstanceID: laneInstanceID,
            snapshot: snapshot
        )
        state = .ready(
            token: activeToken,
            request: request,
            snapshot: snapshot,
            leaseRegistry: leaseRegistry
        )
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.lease.acquired",
            ownerID: token.ownerID,
            instanceID: laneInstanceID.rawValue,
            details: [
                "leaseID": lease.leaseID.uuidString,
                "activeLeaseCount": String(leaseRegistry.count)
            ]
        )
        return lease
    }

    public func releaseLaneLease(
        _ lease: TuringQwenNativeSharedResidencyLease,
        reason: String
    ) throws {
        guard case .ready(
            let token,
            let request,
            let snapshot,
            var leaseRegistry
        ) = state, token == lease.ownerToken else {
            recordInvariantViolation("Stale shared residency lease release.")
            throw TuringQwenNativeError.invalidConfig(
                "Stale shared residency lease release."
            )
        }
        do {
            try leaseRegistry.release(
                leaseID: lease.leaseID,
                laneInstanceID: lease.laneInstanceID
            )
        } catch {
            recordInvariantViolation("Duplicate or mismatched shared residency lease release.")
            throw error
        }
        state = .ready(
            token: token,
            request: request,
            snapshot: snapshot,
            leaseRegistry: leaseRegistry
        )
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.lease.released",
            ownerID: token.ownerID,
            instanceID: lease.laneInstanceID.rawValue,
            details: [
                "leaseID": lease.leaseID.uuidString,
                "activeLeaseCount": String(leaseRegistry.count),
                "reason": reason
            ]
        )
    }

    public func activeLeaseCount(token: Token) throws -> Int {
        guard case .ready(let activeToken, _, _, let leaseRegistry) = state,
              activeToken == token else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency is not ready for this owner token."
            )
        }
        return leaseRegistry.count
    }

    public func residentResourceLoadMetrics(
        token: Token
    ) throws -> TuringQwenNativeResidentResourceLoadMetrics {
        guard case .ready(let activeToken, _, let snapshot, _) = state,
              activeToken == token else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency metrics requested with a stale owner token."
            )
        }
        return snapshot.modelResources.loadMetrics
    }

    #if GR_TURING_QUALIFICATION
    public func captureSharedWeightQualificationSnapshot(
        token: Token
    ) throws -> TuringQwenNativeSharedWeightQualificationSnapshot {
        guard case .ready(let activeToken, _, let snapshot, _) = state,
              activeToken == token else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared weight qualification snapshot requested with a stale owner token."
            )
        }
        return try snapshot.modelResources.weightsStore
            .makeQualificationSampleSnapshot()
    }
    #endif

    public func finish(
        token: Token,
        reason: String
    ) throws -> TuringQwenNativeSharedResidencyFinishReport {
        guard case .ready(let activeToken, _, _, let leaseRegistry) = state,
              activeToken == token else {
            recordInvariantViolation("Shared residency finish used a stale token.")
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency is not ready for this owner token."
            )
        }
        guard leaseRegistry.isEmpty else {
            recordInvariantViolation("Shared residency finished with active lane leases.")
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency finished with active lane leases."
            )
        }
        state = .releasing(token: token)
        state = .released(token: token)
        let memory = TuringQwenNativeResidencyMemorySnapshot.capture()
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.owner.released",
            ownerID: token.ownerID,
            details: ["reason": reason]
        )
        return TuringQwenNativeSharedResidencyFinishReport(
            ownerID: token.ownerID,
            generation: token.generation,
            activeLeaseCountAtFinish: 0,
            reason: reason,
            memoryAfterRelease: memory
        )
    }

    private func recordInvariantViolation(_ message: String) {
        TuringQwenNativeDiagnostics.recordResidencyEvent(
            "qwen.residency.invariantViolation",
            details: ["message": message]
        )
    }

    private func publishReadyIfStillLoading(
        token: Token,
        request: RequestIdentity,
        snapshot: TuringQwenNativeSharedResidencySnapshot
    ) throws {
        switch state {
        case .loading(let activeToken, let activeRequest, _):
            guard activeToken == token, activeRequest == request else {
                throw CancellationError()
            }
            state = .ready(
                token: token,
                request: request,
                snapshot: snapshot,
                leaseRegistry: .init()
            )
        case .ready(let activeToken, let activeRequest, _, _):
            guard activeToken == token, activeRequest == request else {
                throw CancellationError()
            }
        default:
            throw CancellationError()
        }
    }
}
