import MLX
import Testing

@Suite(.serialized)
struct TuringMetalDiagnosticsRingTests {
    @Test
    func boundedRingWrapsAt64WithMonotonicSequences() {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        for _ in 0..<70 {
            TuringMetalDiagnostics.recordSyntheticCompletionForTesting()
        }
        let records = TuringMetalDiagnostics.recentRecords()
        #expect(records.count == 64)
        #expect(records.first?.sequence == 7)
        #expect(records.last?.sequence == 70)
        #expect(TuringMetalDiagnostics.aggregate().completedCount == 70)
    }

    @Test
    func syntheticFailurePoisonsOnceAndRetainsOneFailureRecord() {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        TuringMetalDiagnostics.injectFailureOnNextCompletionForTesting(
            errorCode: 4
        )
        TuringMetalDiagnostics.recordSyntheticCompletionForTesting()
        #expect(TuringMetalDiagnostics.failureEpoch == 1)
        #expect(TuringMetalDiagnostics.isPoisoned)
        #expect(TuringMetalDiagnostics.aggregate().failureCount == 1)
        #expect(TuringMetalDiagnostics.recentRecords().filter(\.isFailure).count == 1)
        #expect(TuringMetalDiagnostics.lastFailure()?.record.errorCode == 4)
    }

    @Test
    func failureEvidenceCannotBeAcknowledgedThroughOrdinarySwiftDiagnostics() {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        TuringMetalDiagnostics.injectFailureOnNextCompletionForTesting(
            errorCode: 1
        )
        TuringMetalDiagnostics.recordSyntheticCompletionForTesting()

        #expect(TuringMetalDiagnostics.failureEpoch == 1)
        #expect(TuringMetalDiagnostics.isPoisoned)
        #expect(TuringMetalDiagnostics.lastFailure() != nil)
        #expect(TuringMetalDiagnostics.aggregate().failureCount == 1)
        #expect(TuringMetalDiagnostics.recentRecords().filter(\.isFailure).count == 1)
    }

    @Test
    func externalMetalCountsAreCopiedWithoutRetainingAProvider() {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        TuringMetalDiagnostics.setExternalInFlightCounts(
            appMetal: 2,
            mindEyeCompositor: 1
        )
        #expect(TuringMetalDiagnostics.externalInFlightCounts().appMetal == 2)
        #expect(TuringMetalDiagnostics.externalInFlightCounts().mindEyeCompositor == 1)
        TuringMetalDiagnostics.recordSyntheticCompletionForTesting()
        #expect(TuringMetalDiagnostics.recentRecords().last?.appMetalInFlightAtSubmit == 2)
        #expect(TuringMetalDiagnostics.recentRecords().last?.mindEyeInFlightAtSubmit == 1)
    }
}
