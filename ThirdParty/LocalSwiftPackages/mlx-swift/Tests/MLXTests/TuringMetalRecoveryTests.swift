import MLX
import Testing

@Suite(.serialized)
struct TuringMetalRecoveryTests {
    @Test
    func failSoftOwnershipIsExclusiveAndPreservesPoisonEvidence() throws {
        TuringMetalRecovery.resetForTesting()
        TuringMetalDiagnostics.resetForTesting()
        defer {
            TuringMetalDiagnostics.resetForTesting()
            TuringMetalRecovery.resetForTesting()
        }

        TuringMetalDiagnostics.injectFailureOnNextCompletionForTesting(
            errorCode: 1
        )
        TuringMetalDiagnostics.recordSyntheticCompletionForTesting()

        let begin = try TuringMetalRecovery.begin(
            expectedFailureEpoch: 1,
            expectedGeneration: 1
        )
        let drained = try TuringMetalRecovery.waitForQuiescence(
            token: begin.token,
            timeout: .seconds(1)
        )
        #expect(drained.activeExecutionCount == 0)
        #expect(drained.inFlightCommandBufferCount == 0)

        let unavailable = try TuringMetalRecovery.markUnavailable(
            token: begin.token,
            resultCode: .unsupported,
            reason: "qualificationRequired"
        )
        #expect(unavailable.state == .unavailable)
        #expect(TuringMetalDiagnostics.isPoisoned)
        #expect(TuringMetalDiagnostics.failureEpoch == 1)
        #expect(
            TuringMetalDiagnostics.recentRecords().filter(\.isFailure).count == 1
        )
    }

    @Test
    func beginRejectsWithoutAnActiveFailure() {
        TuringMetalRecovery.resetForTesting()
        TuringMetalDiagnostics.resetForTesting()
        #expect(throws: TuringMetalRecoveryError.self) {
            try TuringMetalRecovery.begin(
                expectedFailureEpoch: 1,
                expectedGeneration: 1
            )
        }
    }
}
