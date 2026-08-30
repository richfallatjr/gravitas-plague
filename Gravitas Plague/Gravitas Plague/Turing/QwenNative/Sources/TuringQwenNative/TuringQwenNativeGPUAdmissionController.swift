import Foundation

public actor TuringQwenNativeGPUAdmissionController {
    private struct Waiter {
        let id: UUID
        let kind: TuringQwenNativeGPUWorkKind
        let work: TuringQwenNativeGPUWorkIdentity
        let queuedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<
            TuringQwenNativeGPUAdmissionLease,
            Error
        >
    }

    private static let maximumWaiterCount = 16

    private let policy: TuringQwenNativeGPUAdmissionPolicy
    private var activeGenerationLeases: [
        UUID: TuringQwenNativeGPUAdmissionLease
    ] = [:]
    private var activeDecodeLease: TuringQwenNativeGPUAdmissionLease?
    private var generationWaiters: [Waiter] = []
    private var decodeWaiters: [Waiter] = []
    private var peakActiveGenerationLeaseCount = 0
    private var peakQueuedGenerationCount = 0
    private var peakQueuedDecodeCount = 0
    private var generationAcquisitionCount = 0
    private var decodeAcquisitionCount = 0
    private var blockedGenerationAcquisitionCount = 0
    private var blockedDecodeAcquisitionCount = 0
    private var totalGenerationWaitNanoseconds: UInt64 = 0
    private var maximumGenerationWaitNanoseconds: UInt64 = 0
    private var totalDecodeWaitNanoseconds: UInt64 = 0
    private var maximumDecodeWaitNanoseconds: UInt64 = 0
    private var invariantViolationCount = 0
    private var isCancelled = false
    private var diagnosticRunID: String?

    public init(policy: TuringQwenNativeGPUAdmissionPolicy) {
        self.policy = policy
    }

    public func beginRun(runID: String) {
        diagnosticRunID = runID
        recordEvent(
            "gpuAdmission.run.started",
            runID: runID
        )
    }

    public func acquireGeneration(
        work: TuringQwenNativeGPUWorkIdentity
    ) async throws -> TuringQwenNativeGPUAdmissionLease {
        try await acquire(kind: .generation, work: work)
    }

    public func acquireDecode(
        work: TuringQwenNativeGPUWorkIdentity
    ) async throws -> TuringQwenNativeGPUAdmissionLease {
        try await acquire(kind: .speechDecode, work: work)
    }

    public func release(
        _ lease: TuringQwenNativeGPUAdmissionLease,
        reason: String
    ) {
        releaseInternal(lease, reason: reason)
    }

    public func cancelAll(reason: String) {
        guard isCancelled == false else { return }
        isCancelled = true

        let waiters = generationWaiters + decodeWaiters
        generationWaiters.removeAll(keepingCapacity: false)
        decodeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }

        recordEvent(
            "gpuAdmission.run.cancelled",
            reason: reason
        )
        print(
            "[TuringGPUAdmission] cancelled " +
            "reason=\(reason) " +
            "activeGeneration=\(activeGenerationLeases.count) " +
            "activeDecode=\(activeDecodeLease == nil ? 0 : 1)"
        )
    }

    public func finishRun(
        reason: String
    ) throws -> TuringQwenNativeGPUAdmissionSnapshot {
        let value = snapshot()
        guard activeGenerationLeases.isEmpty,
              activeDecodeLease == nil,
              generationWaiters.isEmpty,
              decodeWaiters.isEmpty else {
            recordEvent(
                "gpuAdmission.invariantViolation",
                reason: reason
            )
            throw TuringQwenNativeError.invalidConfig(
                "GPU admission finished with active or queued ownership."
            )
        }

        recordEvent("gpuAdmission.run.finished", reason: reason)
        return value
    }

    public func snapshot() -> TuringQwenNativeGPUAdmissionSnapshot {
        TuringQwenNativeGPUAdmissionSnapshot(
            mode: policy.mode,
            activeGenerationLeaseCount: activeGenerationLeases.count,
            activeDecodeLeaseCount: activeDecodeLease == nil ? 0 : 1,
            queuedGenerationCount: generationWaiters.count,
            queuedDecodeCount: decodeWaiters.count,
            peakActiveGenerationLeaseCount: peakActiveGenerationLeaseCount,
            peakQueuedGenerationCount: peakQueuedGenerationCount,
            peakQueuedDecodeCount: peakQueuedDecodeCount,
            generationAcquisitionCount: generationAcquisitionCount,
            decodeAcquisitionCount: decodeAcquisitionCount,
            blockedGenerationAcquisitionCount:
                blockedGenerationAcquisitionCount,
            blockedDecodeAcquisitionCount: blockedDecodeAcquisitionCount,
            totalGenerationWaitNanoseconds:
                totalGenerationWaitNanoseconds,
            maximumGenerationWaitNanoseconds:
                maximumGenerationWaitNanoseconds,
            totalDecodeWaitNanoseconds: totalDecodeWaitNanoseconds,
            maximumDecodeWaitNanoseconds: maximumDecodeWaitNanoseconds,
            invariantViolationCount: invariantViolationCount
        )
    }

    private func acquire(
        kind: TuringQwenNativeGPUWorkKind,
        work: TuringQwenNativeGPUWorkIdentity
    ) async throws -> TuringQwenNativeGPUAdmissionLease {
        try Task.checkCancellation()
        guard isCancelled == false else {
            throw CancellationError()
        }

        if policy.mode == .currentOverlap {
            recordImmediateAcquisition(kind: kind)
            let lease = TuringQwenNativeGPUAdmissionLease(
                id: UUID(),
                kind: kind,
                work: work,
                isNoOp: true
            )
            recordAcquired(lease, waitNanoseconds: 0)
            return lease
        }

        if canGrantImmediately(kind: kind) {
            return grant(kind: kind, work: work, queuedAt: nil)
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let lease = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<
                    TuringQwenNativeGPUAdmissionLease,
                    Error
                >) in
                enqueue(
                    Waiter(
                        id: waiterID,
                        kind: kind,
                        work: work,
                        queuedAt: .now,
                        continuation: continuation
                    )
                )
            }

            if Task.isCancelled {
                releaseInternal(
                    lease,
                    reason: "cancelledImmediatelyAfterGrant"
                )
                throw CancellationError()
            }
            return lease
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func canGrantImmediately(
        kind: TuringQwenNativeGPUWorkKind
    ) -> Bool {
        switch kind {
        case .generation:
            return activeDecodeLease == nil &&
                decodeWaiters.isEmpty &&
                activeGenerationLeases.count <
                    policy.maximumConcurrentGenerationLeases
        case .speechDecode:
            return activeDecodeLease == nil &&
                activeGenerationLeases.isEmpty
        }
    }

    private func enqueue(_ waiter: Waiter) {
        let totalWaiters = generationWaiters.count + decodeWaiters.count
        guard totalWaiters < Self.maximumWaiterCount else {
            invariantViolationCount += 1
            recordEvent(
                "gpuAdmission.invariantViolation",
                work: waiter.work,
                reason: "waiterBoundExceeded"
            )
            waiter.continuation.resume(
                throwing: TuringQwenNativeError.invalidConfig(
                    "GPU admission exceeded its 16-waiter defensive bound."
                )
            )
            return
        }

        switch waiter.kind {
        case .generation:
            generationWaiters.append(waiter)
            blockedGenerationAcquisitionCount += 1
            peakQueuedGenerationCount = max(
                peakQueuedGenerationCount,
                generationWaiters.count
            )
        case .speechDecode:
            decodeWaiters.append(waiter)
            blockedDecodeAcquisitionCount += 1
            peakQueuedDecodeCount = max(
                peakQueuedDecodeCount,
                decodeWaiters.count
            )
        }
        recordEvent(
            waiter.kind == .generation
                ? "gpuAdmission.generation.waiting"
                : "gpuAdmission.decode.waiting",
            work: waiter.work
        )
    }

    private func grant(
        kind: TuringQwenNativeGPUWorkKind,
        work: TuringQwenNativeGPUWorkIdentity,
        queuedAt: ContinuousClock.Instant?
    ) -> TuringQwenNativeGPUAdmissionLease {
        let lease = TuringQwenNativeGPUAdmissionLease(
            id: UUID(),
            kind: kind,
            work: work,
            isNoOp: false
        )
        let waitNanoseconds: UInt64
        if let queuedAt {
            waitNanoseconds = Self.nanoseconds(
                queuedAt.duration(to: .now)
            )
            recordWait(kind: kind, nanoseconds: waitNanoseconds)
        } else {
            waitNanoseconds = 0
        }

        switch kind {
        case .generation:
            precondition(activeDecodeLease == nil)
            precondition(
                activeGenerationLeases.count <
                    policy.maximumConcurrentGenerationLeases
            )
            activeGenerationLeases[lease.id] = lease
            generationAcquisitionCount += 1
            peakActiveGenerationLeaseCount = max(
                peakActiveGenerationLeaseCount,
                activeGenerationLeases.count
            )
        case .speechDecode:
            precondition(activeDecodeLease == nil)
            precondition(activeGenerationLeases.isEmpty)
            activeDecodeLease = lease
            decodeAcquisitionCount += 1
        }

        recordAcquired(lease, waitNanoseconds: waitNanoseconds)
        return lease
    }

    private func recordImmediateAcquisition(
        kind: TuringQwenNativeGPUWorkKind
    ) {
        switch kind {
        case .generation:
            generationAcquisitionCount += 1
            // Baseline leases are deliberately no-op, but the peak reports the
            // preserved configured two-lane capacity rather than fake ownership.
            peakActiveGenerationLeaseCount = max(
                peakActiveGenerationLeaseCount,
                min(generationAcquisitionCount, 2)
            )
        case .speechDecode:
            decodeAcquisitionCount += 1
        }
    }

    private func recordWait(
        kind: TuringQwenNativeGPUWorkKind,
        nanoseconds: UInt64
    ) {
        switch kind {
        case .generation:
            totalGenerationWaitNanoseconds &+= nanoseconds
            maximumGenerationWaitNanoseconds = max(
                maximumGenerationWaitNanoseconds,
                nanoseconds
            )
        case .speechDecode:
            totalDecodeWaitNanoseconds &+= nanoseconds
            maximumDecodeWaitNanoseconds = max(
                maximumDecodeWaitNanoseconds,
                nanoseconds
            )
        }
    }

    private func releaseInternal(
        _ lease: TuringQwenNativeGPUAdmissionLease,
        reason: String
    ) {
        if lease.isNoOp {
            recordReleased(lease, reason: reason)
            return
        }

        let removed: Bool
        switch lease.kind {
        case .generation:
            removed = activeGenerationLeases.removeValue(
                forKey: lease.id
            ) != nil
        case .speechDecode:
            if activeDecodeLease == lease {
                activeDecodeLease = nil
                removed = true
            } else {
                removed = false
            }
        }

        guard removed else {
            invariantViolationCount += 1
            recordEvent(
                "gpuAdmission.invariantViolation",
                work: lease.work,
                reason: reason
            )
            print(
                "[TuringGPUAdmission] stale/double release ignored " +
                "kind=\(lease.kind.rawValue) " +
                "run=\(lease.work.runID) " +
                "segment=\(lease.work.segmentIndex) " +
                "reason=\(reason)"
            )
            return
        }

        recordReleased(lease, reason: reason)
        drainWaiters()
    }

    private func drainWaiters() {
        guard isCancelled == false,
              activeDecodeLease == nil else {
            return
        }

        if activeGenerationLeases.isEmpty,
           decodeWaiters.isEmpty == false {
            let waiter = decodeWaiters.removeFirst()
            let lease = grant(
                kind: .speechDecode,
                work: waiter.work,
                queuedAt: waiter.queuedAt
            )
            waiter.continuation.resume(returning: lease)
            return
        }

        guard decodeWaiters.isEmpty else { return }
        while activeGenerationLeases.count <
                policy.maximumConcurrentGenerationLeases,
              generationWaiters.isEmpty == false {
            let waiter = generationWaiters.removeFirst()
            let lease = grant(
                kind: .generation,
                work: waiter.work,
                queuedAt: waiter.queuedAt
            )
            waiter.continuation.resume(returning: lease)
        }
    }

    private func cancelWaiter(id: UUID) {
        if let index = generationWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = generationWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        if let index = decodeWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = decodeWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func recordAcquired(
        _ lease: TuringQwenNativeGPUAdmissionLease,
        waitNanoseconds: UInt64
    ) {
        recordEvent(
            lease.kind == .generation
                ? "gpuAdmission.generation.acquired"
                : "gpuAdmission.decode.acquired",
            work: lease.work,
            waitNanoseconds: waitNanoseconds
        )
    }

    private func recordReleased(
        _ lease: TuringQwenNativeGPUAdmissionLease,
        reason: String
    ) {
        recordEvent(
            lease.kind == .generation
                ? "gpuAdmission.generation.released"
                : "gpuAdmission.decode.released",
            work: lease.work,
            reason: reason
        )
    }

    private func recordEvent(
        _ label: String,
        runID: String? = nil,
        work: TuringQwenNativeGPUWorkIdentity? = nil,
        waitNanoseconds: UInt64? = nil,
        reason: String? = nil
    ) {
        var details: [String: String] = [
            "mode": policy.mode.rawValue,
            "generationQueueDepth": String(generationWaiters.count),
            "decodeQueueDepth": String(decodeWaiters.count),
            "activeGenerationCount": String(activeGenerationLeases.count),
            "decoderActive": String(activeDecodeLease != nil)
        ]
        if let work {
            details["laneIndex"] = work.laneIndex.map(String.init) ?? "none"
            details["decodeID"] = work.decodeID.map(String.init) ?? "none"
        }
        if let waitNanoseconds {
            details["waitNanoseconds"] = String(waitNanoseconds)
        }
        if let reason {
            details["reason"] = reason
        }
        let memory = TuringQwenNativeProcessMemoryProbe.snapshot()
        details["availableProcessMemoryMB"] = String(
            format: "%.1f",
            memory.availableProcessMemoryMB
        )

        TuringQwenNativeDiagnostics.recordBreadcrumb(
            label,
            runID: work?.runID ?? runID ?? diagnosticRunID,
            instanceID: work?.instanceID,
            segmentIndex: work?.segmentIndex,
            details: details
        )
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let whole = UInt64(components.seconds)
        let fractional = UInt64(max(components.attoseconds, 0)) / 1_000_000_000
        let (scaled, overflow) = whole.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        guard overflow == false else { return UInt64.max }
        let (total, additionOverflow) = scaled.addingReportingOverflow(
            fractional
        )
        return additionOverflow ? UInt64.max : total
    }
}
