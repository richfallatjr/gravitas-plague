import Foundation
import MLX
import Testing

#if DEBUG
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

    @Test
    func captureRetainsEarlySlowBufferAfterRingWrapAndIgnoresPriorMaximum() throws {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        let prior = try TuringMetalDiagnostics.submitSyntheticForTesting()
        try TuringMetalDiagnostics.completeSyntheticForTesting(prior, gpuEnd: 3, kernelEnd: 2)
        let capture = try TuringMetalCommandBufferCapture()
        let slow = try TuringMetalDiagnostics.submitSyntheticForTesting(mixedContext: true)
        try TuringMetalDiagnostics.completeSyntheticForTesting(slow, gpuEnd: 1.2, kernelEnd: 1.1)
        for _ in 0..<70 {
            let id = try TuringMetalDiagnostics.submitSyntheticForTesting()
            try TuringMetalDiagnostics.completeSyntheticForTesting(id)
        }
        let result = try capture.finish()
        #expect(result.aggregate.submittedCount == 71)
        #expect(result.aggregate.completedCount == 71)
        #expect(result.aggregate.failureCount == 0)
        #expect(abs(result.aggregate.maximumGPUSeconds - 0.2) < 1e-9)
        #expect(abs(result.aggregate.maximumKernelSeconds - 0.1) < 1e-9)
        #expect(abs(result.totalRecordedGPUSeconds - 0.27) < 1e-9)
        #expect(abs(result.totalRecordedKernelSeconds - 0.17) < 1e-9)
        #expect(result.aggregate.durationHistogram["gte150ms"] == 1)
        #expect(result.aggregate.durationHistogram["lt5ms"] == 70)
        #expect(result.slowestRecords.first?.commandBufferID == slow)
        #expect(result.slowestRecords.count == 16)
        #expect(result.mixedContextCount == 1)
        #expect(result.singlePrimitiveOver50msCount == 1)
        #expect(result.pendingCount == 0)
        #expect(!TuringMetalDiagnostics.recentRecords().contains { $0.commandBufferID == slow })
        #expect(result.gpuIntervalUnionSeconds == nil)
    }

    @Test
    func earlyFinishPreservesPendingAndLateCompletionCannotEnterReusedSlot() throws {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        let first = try TuringMetalCommandBufferCapture()
        let late = try TuringMetalDiagnostics.submitSyntheticForTesting()
        #expect(try first.snapshot().pendingCount == 1)
        let exported = try first.finish()
        #expect(exported.aggregate.submittedCount == 1)
        #expect(exported.aggregate.completedCount == 0)
        #expect(exported.pendingCount == 1)
        let second = try TuringMetalCommandBufferCapture()
        try TuringMetalDiagnostics.completeSyntheticForTesting(late, gpuEnd: 2)
        let current = try TuringMetalDiagnostics.submitSyntheticForTesting()
        try TuringMetalDiagnostics.completeSyntheticForTesting(current)
        let result = try second.finish()
        #expect(result.captureID != exported.captureID)
        #expect(result.aggregate.submittedCount == 1)
        #expect(result.aggregate.completedCount == 1)
        #expect(result.pendingCount == 0)
        #expect(try first.finish() == exported)
        #expect(abs(result.aggregate.maximumGPUSeconds - 0.001) < 1e-9)
    }

    @Test
    func overlappingCapturesTrackTheirOwnSubmissionWindows() throws {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        let first = try TuringMetalCommandBufferCapture()
        let firstOnly = try TuringMetalDiagnostics.submitSyntheticForTesting()
        let second = try TuringMetalCommandBufferCapture()
        let both = try TuringMetalDiagnostics.submitSyntheticForTesting()
        try TuringMetalDiagnostics.completeSyntheticForTesting(firstOnly, gpuEnd: 1.5)
        try TuringMetalDiagnostics.completeSyntheticForTesting(both, gpuEnd: 1.05)
        let firstResult = try first.finish()
        let secondOnly = try TuringMetalDiagnostics.submitSyntheticForTesting()
        try TuringMetalDiagnostics.completeSyntheticForTesting(secondOnly, gpuEnd: 1.01)
        let secondResult = try second.finish()
        #expect(firstResult.aggregate.completedCount == 2)
        #expect(secondResult.aggregate.completedCount == 2)
        #expect(abs(firstResult.aggregate.maximumGPUSeconds - 0.5) < 1e-9)
        #expect(abs(secondResult.aggregate.maximumGPUSeconds - 0.05) < 1e-9)
        #expect(abs(firstResult.totalRecordedGPUSeconds - 0.55) < 1e-9)
        #expect(abs(secondResult.totalRecordedGPUSeconds - 0.06) < 1e-9)
    }

    @Test
    func missingInvalidAndMixedContextEvidenceIsExplicit() throws {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        let capture = try TuringMetalCommandBufferCapture()
        let context = TuringMetalExecutionContext(runID: "capture-test", phase: "codePredictor")
        let labelled = try TuringMetalDiagnostics.withContext(context) {
            try TuringMetalDiagnostics.submitSyntheticForTesting()
        }
        try TuringMetalDiagnostics.completeSyntheticForTesting(labelled)
        let mixed = try TuringMetalDiagnostics.withContext(context) {
            try TuringMetalDiagnostics.submitSyntheticForTesting(mixedContext: true)
        }
        try TuringMetalDiagnostics.completeSyntheticForTesting(mixed,
            gpuStart: 0, gpuEnd: 0, kernelStart: 0, kernelEnd: 0)
        let unknown = try TuringMetalDiagnostics.submitSyntheticForTesting()
        TuringMetalDiagnostics.injectFailureOnNextCompletionForTesting(errorCode: 4)
        try TuringMetalDiagnostics.completeSyntheticForTesting(unknown,
            gpuStart: 2, gpuEnd: 1, kernelStart: 2, kernelEnd: 1)
        let result = try capture.finish()
        #expect(result.aggregate.completedCount == 3)
        #expect(result.aggregate.failureCount == 1)
        #expect(result.singleObservedContextCount == 1)
        #expect(result.mixedContextCount == 1)
        #expect(result.unattributedContextCount == 1)
        #expect(result.gpuTimestampSampleCount == 1)
        #expect(result.kernelTimestampSampleCount == 1)
        #expect(result.missingGPUTimestampCount == 1)
        #expect(result.invalidGPUTimestampCount == 1)
        #expect(result.missingKernelTimestampCount == 1)
        #expect(result.invalidKernelTimestampCount == 1)
        #expect(result.aggregate.durationHistogram.values.reduce(0, +) == 1)
    }

    @Test
    func nonfiniteRawTimestampsRemainInvalidEvidenceAndJSONRoundTrips() throws {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        let capture = try TuringMetalCommandBufferCapture()
        let command = try TuringMetalDiagnostics.submitSyntheticForTesting()
        try TuringMetalDiagnostics.completeSyntheticForTesting(command,
            gpuStart: .nan, gpuEnd: .infinity,
            kernelStart: -.infinity, kernelEnd: .nan)
        let result = try capture.finish()
        #expect(result.invalidGPUTimestampCount == 1)
        #expect(result.invalidKernelTimestampCount == 1)
        #expect(result.gpuTimestampSampleCount == 0)
        #expect(result.kernelTimestampSampleCount == 0)
        #expect(result.aggregate.durationHistogram.values.reduce(0, +) == 0)
        let data = try JSONEncoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(object["slowestRecords"] as? [[String: Any]])
        let raw = try #require(records.first)
        #expect((raw["GPUStartSeconds"] as? [String: String])?["invalidNumericValue"] == "NaN")
        #expect((raw["GPUEndSeconds"] as? [String: String])?["invalidNumericValue"] == "positiveInfinity")
        #expect((raw["kernelStartSeconds"] as? [String: String])?["invalidNumericValue"] == "negativeInfinity")
        let decoded = try JSONDecoder().decode(TuringMetalCommandBufferCaptureSummary.self, from: data)
        #expect(decoded.slowestRecords.first?.GPUStartSeconds.isNaN == true)
        #expect(decoded.slowestRecords.first?.GPUEndSeconds == .infinity)
        #expect(decoded.invalidGPUTimestampCount == 1)
        #expect(decoded.invalidKernelTimestampCount == 1)
    }

    @Test
    func captureCapacityFailureIsExplicitAndReleasedSlotsAreReusable() throws {
        TuringMetalDiagnostics.resetForTesting()
        defer { TuringMetalDiagnostics.resetForTesting() }
        let captures = try (0..<8).map { _ in try TuringMetalCommandBufferCapture() }
        #expect(throws: (any Error).self) { try TuringMetalCommandBufferCapture() }
        _ = try captures[0].finish()
        let replacement = try TuringMetalCommandBufferCapture()
        _ = try replacement.finish()
        for capture in captures { _ = try capture.finish() }
    }
}
#endif
