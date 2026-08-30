import Foundation
import MLX

public actor TuringQwenNativeRecoveryCoordinator {
    public static let shared = TuringQwenNativeRecoveryCoordinator()

    private enum LowLevelProgress: Sendable {
        case resetting
        case probing(TuringQwenNativeRecoveryGeneration)
    }

    private let policy: TuringQwenNativeRecoveryPolicy
    private var state: TuringQwenNativeRecoveryState = .ready(
        generation: .initial
    )
    private var availability: TuringQwenNativeRecoveryAvailability = .ready(
        generation: TuringQwenNativeRecoveryGeneration.initial.rawValue
    )
    private var launchAttemptCount = 0
    private var activeFailure: TuringQwenNativeRecoveryFailureContext?
    private var activeReleaseReceipt: TuringQwenNativeRecoveryReleaseReceipt?
    private var activeBaselineBytes: UInt64 = 0
    private var recoveryTransitions: [TuringQwenNativeRecoveryTransition] = []
    private var currentRecoveryTask: Task<
        TuringQwenNativeRecoveryOutcome,
        Never
    >?
    private var availabilityContinuations: [
        UUID: AsyncStream<TuringQwenNativeRecoveryAvailability>.Continuation
    ] = [:]

    public init(policy: TuringQwenNativeRecoveryPolicy = .current) {
        self.policy = policy
    }

    public func acquireSessionAdmission(
        sessionID: UUID,
        runID: String
    ) throws -> TuringQwenNativeRecoverySessionAdmission {
        switch state {
        case .ready(let generation), .readyForFreshRuntime(let generation):
            return .init(
                sessionID: sessionID,
                runID: runID,
                generation: generation
            )
        case .failing, .draining, .resettingMetal, .probing:
            throw TuringQwenNativeRecoveryUnavailableError(
                availability: .recovering
            )
        case .unavailable(let reason):
            throw TuringQwenNativeRecoveryUnavailableError(
                availability: .unavailableUntilRelaunch(reason: reason)
            )
        case .shuttingDown:
            throw TuringQwenNativeRecoveryUnavailableError(
                availability: .unavailableUntilRelaunch(
                    reason: .shutdownDuringRecovery
                )
            )
        }
    }

    public func requireReady() throws {
        switch state {
        case .ready, .readyForFreshRuntime:
            return
        case .failing, .draining, .resettingMetal, .probing:
            throw TuringQwenNativeRecoveryUnavailableError(
                availability: .recovering
            )
        case .unavailable(let reason):
            throw TuringQwenNativeRecoveryUnavailableError(
                availability: .unavailableUntilRelaunch(reason: reason)
            )
        case .shuttingDown:
            throw TuringQwenNativeRecoveryUnavailableError(
                availability: .unavailableUntilRelaunch(
                    reason: .shutdownDuringRecovery
                )
            )
        }
    }

    public func isPublishable(
        generation: TuringQwenNativeRecoveryGeneration
    ) -> Bool {
        switch state {
        case .ready(let active), .readyForFreshRuntime(let active):
            return generation == active
        default:
            return false
        }
    }

    public func recordFirstFailure(
        _ failure: TuringQwenNativeMetalFailure,
        generation: TuringQwenNativeRecoveryGeneration
    ) {
        guard activeFailure == nil else { return }
        let activeGeneration: TuringQwenNativeRecoveryGeneration
        switch state {
        case .ready(let value), .readyForFreshRuntime(let value):
            activeGeneration = value
        default:
            return
        }
        guard generation == activeGeneration else { return }
        launchAttemptCount += 1
        let context = TuringQwenNativeRecoveryFailureContext(
            recoveryID: UUID(),
            originalGeneration: generation,
            failure: failure,
            firstFailureUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            attemptNumberForLaunch: launchAttemptCount
        )
        activeFailure = context
        state = .failing(context)
        recoveryTransitions = []
        appendTransition("failing")
        publish(.recovering)
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "qwen.recovery.failureRecorded",
            runID: failure.record.record.lastContext.runID,
            segmentIndex: failure.record.record.lastContext.segmentIndex,
            details: [
                "generation": String(generation.rawValue),
                "failureEpoch": String(failure.record.record.failureEpoch),
                "commandBufferID": String(failure.record.record.commandBufferID),
                "attemptForLaunch": String(launchAttemptCount)
            ]
        )
    }

    public func beginAfterOwnershipRelease(
        receipt: TuringQwenNativeRecoveryReleaseReceipt,
        baselineActiveBytes: UInt64
    ) {
        guard currentRecoveryTask == nil,
              let context = activeFailure,
              receipt.generation == context.originalGeneration else {
            return
        }
        activeReleaseReceipt = receipt
        activeBaselineBytes = baselineActiveBytes
        guard receipt.isComplete else {
            appendTransition("unavailable.ownershipDrainTimedOut")
            persistReport(
                context: context,
                outcome: .unavailable(.ownershipDrainTimedOut),
                captureLowLevel: false
            )
            transitionUnavailable(.ownershipDrainTimedOut)
            return
        }
        guard launchAttemptCount <= policy.maximumAttemptsPerLaunch else {
            appendTransition("unavailable.launchAttemptBudgetExceeded")
            persistReport(
                context: context,
                outcome: .unavailable(.launchAttemptBudgetExceeded),
                captureLowLevel: false
            )
            transitionUnavailable(.launchAttemptBudgetExceeded)
            return
        }
        state = .draining(context)
        appendTransition("draining")
        let policy = self.policy
        currentRecoveryTask = Task { [context] in
            let outcome = await Self.performRecovery(
                context: context,
                policy: policy,
                baselineActiveBytes: baselineActiveBytes,
                progress: { progress in
                    await self.apply(progress, context: context)
                }
            )
            self.complete(outcome, context: context)
            return outcome
        }
    }

    public func currentState() -> TuringQwenNativeRecoveryState {
        state
    }

    public func currentAvailability() -> TuringQwenNativeRecoveryAvailability {
        availability
    }

    public func availabilityUpdates() -> AsyncStream<
        TuringQwenNativeRecoveryAvailability
    > {
        let id = UUID()
        return AsyncStream { continuation in
            availabilityContinuations[id] = continuation
            continuation.yield(availability)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeAvailabilityContinuation(id) }
            }
        }
    }

    public func waitUntilRecoverySettles()
        async -> TuringQwenNativeRecoveryAvailability
    {
        if availability != .recovering {
            return availability
        }
        let updates = availabilityUpdates()
        for await update in updates where update != .recovering {
            return update
        }
        return availability
    }

    public func applicationDidEnterBackground() async {
        await failClosedIfRecoveryIsActive(
            reason: .appBackgroundedDuringRecovery
        )
    }

    public func shutdown() async {
        await failClosedIfRecoveryIsActive(reason: .shutdownDuringRecovery)
    }

    private func failClosedIfRecoveryIsActive(
        reason: TuringQwenNativeRecoveryUnavailableReason
    ) async {
        switch state {
        case .failing, .draining, .resettingMetal, .probing:
            break
        case .ready, .readyForFreshRuntime, .unavailable, .shuttingDown:
            return
        }
        state = .shuttingDown
        currentRecoveryTask?.cancel()
        _ = await currentRecoveryTask?.value
        currentRecoveryTask = nil
        activeFailure = nil
        state = .unavailable(reason)
        publish(.unavailableUntilRelaunch(reason: reason))
    }

    private static func performRecovery(
        context: TuringQwenNativeRecoveryFailureContext,
        policy: TuringQwenNativeRecoveryPolicy,
        baselineActiveBytes: UInt64,
        progress: @escaping @Sendable (LowLevelProgress) async -> Void
    ) async -> TuringQwenNativeRecoveryOutcome {
        await Task.detached(priority: .userInitiated) {
            let begin: TuringMetalRecoveryBeginResult
            do {
                begin = try TuringMetalRecovery.begin(
                    expectedFailureEpoch:
                        context.failure.record.record.failureEpoch,
                    expectedGeneration: context.originalGeneration.rawValue
                )
            } catch {
                return .unavailable(.lowLevelRecoveryRejected)
            }

            if policy.lowLevelMode == .failSoftUnavailable {
                _ = try? TuringMetalRecovery.markUnavailable(
                    token: begin.token,
                    resultCode: .unsupported,
                    reason: TuringQwenNativeRecoveryUnavailableReason
                        .productionRecoveryUnqualified.rawValue
                )
                return .unavailable(.productionRecoveryUnqualified)
            }

            do {
                _ = try TuringMetalRecovery.waitForQuiescence(
                    token: begin.token,
                    timeout: policy.metalDrainTimeout
                )
                await progress(.resetting)
                let reset = try TuringMetalRecovery.resetStreams(
                    token: begin.token,
                    baselineActiveBytes: baselineActiveBytes,
                    residualToleranceBytes:
                        policy.residualActiveToleranceBytes
                )
                let candidate = TuringQwenNativeRecoveryGeneration(
                    rawValue: reset.candidateGeneration
                )
                await progress(.probing(candidate))
                let probe = try TuringMetalRecovery.runProbe(
                    token: begin.token,
                    timeout: policy.probeTimeout
                )
                let final = try TuringMetalRecovery.finish(
                    token: begin.token,
                    probe: probe
                )
                guard final.state == .ready,
                      final.generation == candidate.rawValue else {
                    throw TuringQwenNativeRecoveryUnavailableError(
                        availability: .unavailableUntilRelaunch(
                            reason: .healthProbeFailed
                        )
                    )
                }
                return .recovered(generation: candidate)
            } catch let error as TuringMetalRecoveryError {
                let reason: TuringQwenNativeRecoveryUnavailableReason
                switch error.resultCode {
                case .drainTimedOut, .activeExecution, .inFlightBuffers:
                    reason = .metalDrainTimedOut
                case .residencyLeak:
                    reason = .residencyLeak
                case .probeFailed:
                    reason = .healthProbeFailed
                default:
                    reason = .streamResetFailed
                }
                _ = try? TuringMetalRecovery.markUnavailable(
                    token: begin.token,
                    resultCode: error.resultCode,
                    reason: reason.rawValue
                )
                return .unavailable(reason)
            } catch {
                _ = try? TuringMetalRecovery.markUnavailable(
                    token: begin.token,
                    resultCode: .unsupported,
                    reason: TuringQwenNativeRecoveryUnavailableReason
                        .streamResetFailed.rawValue
                )
                return .unavailable(.streamResetFailed)
            }
        }.value
    }

    private func apply(
        _ progress: LowLevelProgress,
        context: TuringQwenNativeRecoveryFailureContext
    ) {
        guard activeFailure?.recoveryID == context.recoveryID else { return }
        switch progress {
        case .resetting:
            state = .resettingMetal(context)
            appendTransition("resettingMetal")
        case .probing(let generation):
            state = .probing(
                context: context,
                candidateGeneration: generation
            )
            appendTransition("probing.\(generation.rawValue)")
        }
    }

    private func complete(
        _ outcome: TuringQwenNativeRecoveryOutcome,
        context: TuringQwenNativeRecoveryFailureContext
    ) {
        guard activeFailure?.recoveryID == context.recoveryID else { return }
        currentRecoveryTask = nil
        switch outcome {
        case .recovered(let generation):
            state = .readyForFreshRuntime(generation: generation)
            appendTransition("readyForFreshRuntime.\(generation.rawValue)")
            persistReport(context: context, outcome: outcome)
            activeFailure = nil
            publish(.ready(generation: generation.rawValue))
        case .unavailable(let reason):
            appendTransition("unavailable.\(reason.rawValue)")
            persistReport(context: context, outcome: outcome)
            transitionUnavailable(reason)
        }
        activeReleaseReceipt = nil
        recoveryTransitions = []
    }

    private func transitionUnavailable(
        _ reason: TuringQwenNativeRecoveryUnavailableReason
    ) {
        state = .unavailable(reason)
        activeFailure = nil
        publish(.unavailableUntilRelaunch(reason: reason))
        activeReleaseReceipt = nil
        recoveryTransitions = []
    }

    private func appendTransition(_ state: String) {
        recoveryTransitions.append(
            .init(
                state: state,
                uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        )
    }

    private func persistReport(
        context: TuringQwenNativeRecoveryFailureContext,
        outcome: TuringQwenNativeRecoveryOutcome,
        captureLowLevel: Bool = true
    ) {
        let lowLevel = captureLowLevel
            ? try? TuringMetalRecovery.snapshot()
            : nil
        let receipt = activeReleaseReceipt
        let failure = context.failure.record.record
        let candidateGeneration: UInt64?
        switch state {
        case .probing(_, let candidate):
            candidateGeneration = candidate.rawValue
        case .readyForFreshRuntime(let generation):
            candidateGeneration = generation.rawValue
        default:
            candidateGeneration = nil
        }
        let result: String
        let unavailableReason: String?
        switch outcome {
        case .recovered:
            result = "recovered"
            unavailableReason = nil
        case .unavailable(let reason):
            result = "unavailable"
            unavailableReason = reason.rawValue
        }
        let commandBufferID = failure.commandBufferID
        let transitionCounts = [
            "final": lowLevel?.inFlightCommandBufferCount ?? 0
        ]
        let probeCommandBufferID: UInt64?
        if let value = lowLevel?.lastProbeCommandBufferID, value != 0 {
            probeCommandBufferID = value
        } else {
            probeCommandBufferID = nil
        }
        let memory = TuringQwenNativeRecoveryMemoryReport(
            baselineActiveBytes: activeBaselineBytes,
            activeBytesAfterOwnershipRelease:
                receipt?.MLXActiveBytesAfterRelease,
            cacheBytesAfterOwnershipRelease:
                receipt?.MLXCacheBytesAfterRelease,
            finalActiveBytes: lowLevel?.MLXActiveBytes,
            finalCacheBytes: lowLevel?.MLXCacheBytes,
            finalPeakBytes: lowLevel?.MLXPeakBytes
        )
        let report = TuringQwenNativeRecoveryReport(
                schemaVersion: 1,
                recoveryID: context.recoveryID,
                originalRunID:
                    failure.lastContext.runID ?? receipt?.runID ?? "unknown",
                originalGeneration: context.originalGeneration.rawValue,
                candidateGeneration: candidateGeneration,
                finalGeneration: lowLevel?.generation,
                firstFailureEpoch: failure.failureEpoch,
                firstFailedCommandBufferID: commandBufferID,
                failurePhase: failure.lastContext.phase,
                failureStage: failure.lastContext.stage,
                failureLane: failure.lastContext.laneIndex,
                failureSegment: failure.lastContext.segmentIndex,
                failureDecodeID: failure.lastContext.decodeID,
                attemptForFailure: 1,
                attemptForLaunch: context.attemptNumberForLaunch,
                transitions: recoveryTransitions,
                laneReleaseReceipts: receipt?.laneReceipts ?? [],
                decoderReleaseReceipt: receipt?.decoderReceipt,
                admissionReleaseReceipt: receipt?.admissionReceipt,
                MLXInFlightAtTransitions: transitionCounts,
                streamResetCount: lowLevel?.streamResetCount ?? 0,
                queueRecreationCount: lowLevel?.queueRecreationCount ?? 0,
                probeCommandBufferID: probeCommandBufferID,
                probeResult: lowLevel.map { $0.reason },
                memory: memory,
                result: result,
                unavailableReason: unavailableReason
        )
        TuringQwenNativeRecoveryReportWriter.persist(report)
    }

    private func publish(
        _ value: TuringQwenNativeRecoveryAvailability
    ) {
        availability = value
        for continuation in availabilityContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeAvailabilityContinuation(_ id: UUID) {
        availabilityContinuations[id] = nil
    }

    #if DEBUG
    public func resetForTesting() {
        currentRecoveryTask?.cancel()
        currentRecoveryTask = nil
        launchAttemptCount = 0
        activeFailure = nil
        state = .ready(generation: .initial)
        publish(.ready(generation: 1))
        TuringMetalRecovery.resetForTesting()
    }
    #endif
}
