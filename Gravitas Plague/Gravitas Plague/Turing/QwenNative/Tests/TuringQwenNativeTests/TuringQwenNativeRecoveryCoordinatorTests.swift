import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeRecoveryCoordinatorTests {
    @Test
    func configuredBuildUsesArchitectedRecovery() {
        #if GR_TURING_METAL_RECOVERY_QUALIFICATION
        #expect(
            TuringQwenNativeRecoveryPolicy.current.lowLevelMode ==
                .resetStreamsThenProbe
        )
        #expect(
            TuringQwenNativeRecoveryPolicy.current.maximumAttemptsPerLaunch == 12
        )
        #elseif GR_TURING_METAL_STREAM_RECOVERY
        #expect(
            TuringQwenNativeRecoveryPolicy.current.lowLevelMode ==
                .resetStreamsThenProbe
        )
        #expect(
            TuringQwenNativeRecoveryPolicy.current.maximumAttemptsPerLaunch == 3
        )
        #else
        Issue.record("Same-launch recovery is not enabled for this build.")
        #endif
    }

    @Test
    func admissionCarriesInitialGeneration() async throws {
        let coordinator = TuringQwenNativeRecoveryCoordinator(
            policy: .production
        )
        let admission = try await coordinator.acquireSessionAdmission(
            sessionID: UUID(),
            runID: "test"
        )
        #expect(
            admission.generation ==
                TuringQwenNativeRecoveryGeneration.initial
        )
        #expect(await coordinator.isPublishable(generation: .initial))
    }

    @Test
    func firstFailureWinsAndClosesAdmissionAndPublication() async throws {
        let coordinator = TuringQwenNativeRecoveryCoordinator(
            policy: .production
        )
        let first = TuringQwenNativeMetalFailure(
            record: .testing(commandBufferID: 17, failureEpoch: 1)
        )
        let second = TuringQwenNativeMetalFailure(
            record: .testing(commandBufferID: 99, failureEpoch: 2)
        )
        await coordinator.recordFirstFailure(first, generation: .initial)
        await coordinator.recordFirstFailure(second, generation: .initial)

        guard case .failing(let context) = await coordinator.currentState() else {
            Issue.record("Coordinator did not enter failing.")
            return
        }
        #expect(context.failure.record.record.commandBufferID == 17)
        #expect(await coordinator.isPublishable(generation: .initial) == false)
        #expect(await coordinator.currentAvailability() == .recovering)
        await #expect(throws: TuringQwenNativeRecoveryUnavailableError.self) {
            try await coordinator.acquireSessionAdmission(
                sessionID: UUID(),
                runID: "blocked"
            )
        }
    }

    @Test
    func incompleteReleaseReceiptFailsSoftWithoutStartingReset() async {
        let coordinator = TuringQwenNativeRecoveryCoordinator(
            policy: .production
        )
        let failure = TuringQwenNativeMetalFailure(
            record: .testing(commandBufferID: 17, failureEpoch: 1)
        )
        await coordinator.recordFirstFailure(failure, generation: .initial)
        await coordinator.beginAfterOwnershipRelease(
            receipt: .init(
                sessionID: UUID(),
                runID: "test",
                generation: .initial,
                poolID: UUID(),
                laneReceipts: [
                    .init(
                        instanceID: "fresh-0",
                        generation: .initial,
                        mutableStateID: nil,
                        residentResourceID: nil,
                        weightStoreID: nil,
                        sharedOwnerID: nil,
                        engineReleased: true,
                        mutableStateReleased: true,
                        residencyReleased: true,
                        activeRenderCount: 0
                    )
                ],
                decoderReceipt: .notStarted(
                    runID: "test",
                    generation: .initial
                ),
                admissionReceipt: .notStarted(generation: .initial),
                sharedResidencyReceipt: nil,
                queueCancelled: true,
                releaseLedgerCleared: true,
                MLXActiveBytesAfterRelease: 0,
                MLXCacheBytesAfterRelease: 0
            ),
            baselineActiveBytes: 0
        )
        #expect(
            await coordinator.currentAvailability() ==
                .unavailableUntilRelaunch(reason: .ownershipDrainTimedOut)
        )
    }

    @Test
    func recoveryGenerationIsMonotonic() throws {
        #expect(
            try TuringQwenNativeRecoveryGeneration.initial.successor() ==
                .init(rawValue: 2)
        )
    }
}
