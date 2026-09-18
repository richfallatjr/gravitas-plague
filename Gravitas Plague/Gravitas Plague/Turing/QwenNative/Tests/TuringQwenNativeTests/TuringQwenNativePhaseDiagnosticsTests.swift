import Dispatch
import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativePhaseDiagnosticsTests {
    @Test func disabledScopesDoNotEvaluateMetadataOrDetails() {
        TuringQwenNativePhaseDiagnostics.$enabled.withValue(false) {
            var evaluated = false
            let context = TuringQwenNativePhaseDiagnostics.makeContext(
                runID: { evaluated = true; return "unexpected" }(),
                lane: { evaluated = true; return "unexpected" }(),
                segmentIndex: 0
            )
            #expect(context == nil)
            TuringQwenNativePhaseDiagnostics.$current.withValue(context) {
                let span = TuringQwenNativePhaseDiagnostics.begin(
                    "Disabled", detail: { evaluated = true; return "unexpected" }()
                )
                #expect(span == nil)
                TuringQwenNativePhaseDiagnostics.tensor("disabled", { fatalError("Metadata must not touch tensors when disabled") }())
                let value = TuringQwenNativePhaseDiagnostics.measure(
                    "DisabledMeasure", detail: { evaluated = true; return "unexpected" }()
                ) { 42 }
                #expect(value == 42)
            }
            #expect(evaluated == false)
        }
    }

    @Test func intervalsBoundBothPerPhaseAndTotal() {
        let limiter = TuringQwenNativePhaseDiagnostics.Limiter(maximumIntervals: 3, maximumPerPhase: 2)
        #expect(limiter.reserveInterval(phase: "row"))
        #expect(limiter.reserveInterval(phase: "row"))
        #expect(!limiter.reserveInterval(phase: "row"))
        #expect(limiter.reserveInterval(phase: "prefill"))
        #expect(!limiter.reserveInterval(phase: "decode"))
    }

    @Test func metadataSamplesUniqueShapeDtypeChangesWithCaps() {
        let limiter = TuringQwenNativePhaseDiagnostics.Limiter(maximumMetadata: 3, maximumShapesPerRole: 2)
        #expect(limiter.reserveMetadata(role: "q", shape: [1, 8, 1, 128], dtype: "bfloat16"))
        #expect(!limiter.reserveMetadata(role: "q", shape: [1, 8, 1, 128], dtype: "bfloat16"))
        #expect(limiter.reserveMetadata(role: "q", shape: [1, 8, 1, 128], dtype: "float32"))
        #expect(!limiter.reserveMetadata(role: "q", shape: [1, 8, 2, 128], dtype: "float32"))
        #expect(limiter.reserveMetadata(role: "v", shape: [1], dtype: "float32"))
        #expect(!limiter.reserveMetadata(role: "pcm", shape: [20], dtype: "float32"))
        #expect(!limiter.reserveInspection(role: "pcm"))
    }

    @Test func metadataInspectionItselfIsBoundedEvenWhenShapeNeverChanges() {
        let limiter = TuringQwenNativePhaseDiagnostics.Limiter()
        for _ in 0..<16 { #expect(limiter.reserveInspection(role: "constant")) }
        #expect(!limiter.reserveInspection(role: "constant"))
    }

    @Test func signpostIDsAreDistinctForOverlappingLanes() {
        let left = TuringQwenNativePhaseDiagnostics.Context(runID: "sameRun", lane: "render.0", segmentIndex: 0)
        let right = TuringQwenNativePhaseDiagnostics.Context(runID: "sameRun", lane: "render.1", segmentIndex: 1)
        let first = TuringQwenNativePhaseDiagnostics.begin("Overlap", context: left)
        let second = TuringQwenNativePhaseDiagnostics.begin("Overlap", context: right)
        defer {
            TuringQwenNativePhaseDiagnostics.end(first)
            TuringQwenNativePhaseDiagnostics.end(second)
        }
        #expect(first != nil)
        #expect(second != nil)
        #expect(first?.id.rawValue != second?.id.rawValue)
    }

    @Test func recorderDoesNotEnableDisabledDiagnosticsOrTouchTensorAutoclosures() {
        let recorder = TuringQwenNativePhaseDiagnostics.RecordingSession()
        TuringQwenNativePhaseDiagnostics.$enabled.withValue(false) {
            TuringQwenNativePhaseDiagnostics.$recordingSession.withValue(recorder) {
                #expect(!TuringQwenNativePhaseDiagnostics.isEnabled)
                let context = TuringQwenNativePhaseDiagnostics.makeContext(
                    runID: "disabled", lane: "render.0", segmentIndex: 0)
                #expect(context == nil)
                TuringQwenNativePhaseDiagnostics.$current.withValue(context) {
                    TuringQwenNativePhaseDiagnostics.tensor(
                        "disabled", { fatalError("Disabled recorder must not touch a tensor") }())
                    TuringQwenNativePhaseDiagnostics.event(
                        "Disabled", detail: { fatalError("Disabled recorder must not inspect event details") }())
                    TuringQwenNativePhaseDiagnostics.metadata(role: "disabled", shape: [1], dtype: "float32")
                }
            }
        }
        let report = recorder.snapshot()
        #expect(report.scopes.isEmpty)
        #expect(report.metadata.isEmpty)
        #expect(report.events.isEmpty)
        #expect(report.scopeAttemptCount == 0)
        #expect(report.metadataAttemptCount == 0)
        #expect(report.eventAttemptCount == 0)
    }

    @Test func elapsedScopesPreserveNestingPendingAndInvalidTimestamps() throws {
        let recorder = TuringQwenNativePhaseDiagnostics.RecordingSession()
        let context = TuringQwenNativePhaseDiagnostics.RecordContext(runID: "run", lane: "decoder", segmentIndex: 2)
        let outer = try #require(recorder.beginScope(
            phase: "SpeechDecodeCPU", context: context, detail: "outer", timestampNanoseconds: 10))
        let inner = try #require(recorder.beginScope(
            phase: "DecoderStageExistingEvalCPU", context: context,
            detail: "speechDecoder.preConv", timestampNanoseconds: 20))
        recorder.endScope(inner, timestampNanoseconds: 40)
        recorder.endScope(outer, timestampNanoseconds: 110)
        // Ending twice must not rewrite the elapsed interval.
        recorder.endScope(inner, timestampNanoseconds: 80)
        let pending = try #require(recorder.beginScope(
            phase: "Pending", context: context, detail: "", timestampNanoseconds: 200))
        #expect(pending == 2)
        let invalid = try #require(recorder.beginScope(
            phase: "Invalid", context: context, detail: "", timestampNanoseconds: 300))
        recorder.endScope(invalid, timestampNanoseconds: 299)

        let report = recorder.snapshot()
        #expect(report.scopes[outer].durationNanoseconds == 100)
        #expect(report.scopes[inner].durationNanoseconds == 20)
        #expect(report.scopes[inner].detail == "speechDecoder.preConv")
        #expect(report.scopes[inner].context == context)
        #expect(report.scopes[pending].endNanoseconds == nil)
        #expect(report.scopes[invalid].durationNanoseconds == nil)
        #expect(report.pendingScopeCount == 1)
        #expect(report.invalidScopeTimestampCount == 1)
        #expect(report.durationSemantics.contains("overlap"))
        #expect(report.durationSemantics.contains("Not CPU time"))
        let decoded = try JSONDecoder().decode(
            TuringQwenNativePhaseDiagnostics.Report.self, from: JSONEncoder().encode(report))
        #expect(decoded.scopes == report.scopes)
        #expect(decoded.pendingScopeCount == 1)
    }

    @Test func recorderGlobalCapsAndDetailTruncationRemainVisible() throws {
        let recorder = TuringQwenNativePhaseDiagnostics.RecordingSession(
            maximumScopes: 1, maximumMetadata: 1, maximumEvents: 1)
        let context = TuringQwenNativePhaseDiagnostics.RecordContext(runID: "run", lane: "render.0", segmentIndex: 0)
        let longDetail = String(repeating: "x", count: 600)
        _ = recorder.beginScope(phase: "first", context: context, detail: longDetail, timestampNanoseconds: 1)
        #expect(recorder.beginScope(phase: "second", context: context, detail: "", timestampNanoseconds: 2) == nil)
        recorder.recordDroppedScope()
        recorder.recordMetadata(context: context, role: "q", shape: [1, 8, 1, 128], dtype: "bfloat16", timestampNanoseconds: 3)
        recorder.recordMetadata(context: context, role: "v", shape: [1], dtype: "float32", timestampNanoseconds: 4)
        recorder.recordSuppressedMetadata(.duplicate)
        recorder.recordSuppressedMetadata(.inspectionLimit)
        recorder.recordEvent(name: "PCMReady", context: context, detail: longDetail, timestampNanoseconds: 5)
        recorder.recordEvent(name: "PCMReady", context: context, detail: "", timestampNanoseconds: 6)
        recorder.recordDroppedEvent()

        let report = recorder.snapshot()
        #expect(report.scopes.count == 1)
        #expect(report.scopeAttemptCount == 3)
        #expect(report.droppedScopeCount == 2)
        #expect(report.scopes[0].detail.count == 512)
        #expect(report.scopes[0].detailTruncated)
        #expect(report.metadata.count == 1)
        #expect(report.metadata[0].shape == [1, 8, 1, 128])
        #expect(report.metadata[0].dtype == "bfloat16")
        #expect(report.metadataAttemptCount == 4)
        #expect(report.droppedMetadataCount == 2)
        #expect(report.duplicateMetadataCount == 1)
        #expect(report.inspectionLimitDropCount == 1)
        #expect(report.events.count == 1)
        #expect(report.events[0].detail.count == 512)
        #expect(report.events[0].detailTruncated)
        #expect(report.eventAttemptCount == 3)
        #expect(report.droppedEventCount == 2)
    }

    @Test func existingLimiterDropsAndSessionOwnershipAreRecorded() throws {
        let recorder = TuringQwenNativePhaseDiagnostics.RecordingSession()
        let retainedSpan = TuringQwenNativePhaseDiagnostics.$enabled.withValue(true) {
            TuringQwenNativePhaseDiagnostics.$recordingSession.withValue(recorder) {
                let context = TuringQwenNativePhaseDiagnostics.makeContext(
                    runID: "run", lane: "decoder", segmentIndex: 0)
                return TuringQwenNativePhaseDiagnostics.$current.withValue(context) {
                    for _ in 0..<34 {
                        let span = TuringQwenNativePhaseDiagnostics.begin("DecoderStageExistingEvalCPU", detail: "stage")
                        TuringQwenNativePhaseDiagnostics.end(span)
                    }
                    TuringQwenNativePhaseDiagnostics.metadata(role: "q", shape: [1], dtype: "bfloat16")
                    TuringQwenNativePhaseDiagnostics.metadata(role: "q", shape: [1], dtype: "bfloat16")
                    for dimension in 2...5 {
                        TuringQwenNativePhaseDiagnostics.metadata(role: "q", shape: [dimension], dtype: "bfloat16")
                    }
                    return TuringQwenNativePhaseDiagnostics.begin("RetainedOwner")
                }
            }
        }
        // Span completion still belongs to the original recorder after the
        // task-local binding has ended; no process-global collector is needed.
        TuringQwenNativePhaseDiagnostics.end(retainedSpan)
        let report = recorder.snapshot()
        #expect(report.scopes.count == 33)
        #expect(report.scopeAttemptCount == 35)
        #expect(report.droppedScopeCount == 2)
        #expect(report.pendingScopeCount == 0)
        #expect(report.metadata.count == 4)
        #expect(report.metadataAttemptCount == 6)
        #expect(report.duplicateMetadataCount == 1)
        #expect(report.droppedMetadataCount == 1)
        #expect(report.maximumIntervalsPerContext == 512)
        #expect(report.maximumIntervalsPerPhasePerContext == 32)
    }

    @Test func concurrentLanesRespectGlobalCapAndKeepCompleteCounts() {
        let recorder = TuringQwenNativePhaseDiagnostics.RecordingSession(maximumScopes: 64)
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            let context = TuringQwenNativePhaseDiagnostics.RecordContext(
                runID: "run", lane: "render.\(index % 2)", segmentIndex: index)
            if let record = recorder.beginScope(
                phase: "Concurrent", context: context, detail: "",
                timestampNanoseconds: UInt64(index * 10)) {
                recorder.endScope(record, timestampNanoseconds: UInt64(index * 10 + 5))
            }
        }
        let report = recorder.snapshot()
        #expect(report.scopes.count == 64)
        #expect(report.scopeAttemptCount == 1_000)
        #expect(report.droppedScopeCount == 936)
        #expect(report.pendingScopeCount == 0)
        #expect(report.invalidScopeTimestampCount == 0)
        #expect(report.scopes.allSatisfy { $0.durationNanoseconds == 5 })
        #expect(Set(report.scopes.map { $0.context.segmentIndex }).count == 64)
    }

    @Test func exhaustedInspectionBudgetDoesNotTouchTensorAndReportsTheDrop() {
        let recorder = TuringQwenNativePhaseDiagnostics.RecordingSession()
        TuringQwenNativePhaseDiagnostics.$recordingSession.withValue(recorder) {
            let context = TuringQwenNativePhaseDiagnostics.Context(runID: "run", lane: "render.0", segmentIndex: 0)
            for _ in 0..<16 { #expect(context.limiter.reserveInspection(role: "capped")) }
            TuringQwenNativePhaseDiagnostics.$current.withValue(context) {
                TuringQwenNativePhaseDiagnostics.tensor(
                    "capped", { fatalError("Inspection limit must stop the tensor autoclosure") }())
            }
        }
        let report = recorder.snapshot()
        #expect(report.metadata.isEmpty)
        #expect(report.metadataAttemptCount == 1)
        #expect(report.droppedMetadataCount == 1)
        #expect(report.inspectionLimitDropCount == 1)
    }

    @Test func taskLocalRecorderIsInheritedByConcurrentChildren() async {
        let recorder = TuringQwenNativePhaseDiagnostics.RecordingSession()
        await TuringQwenNativePhaseDiagnostics.$enabled.withValue(true) {
            await TuringQwenNativePhaseDiagnostics.$recordingSession.withValue(recorder) {
                await withTaskGroup(of: Void.self) { group in
                    for lane in 0..<2 {
                        group.addTask {
                            let context = TuringQwenNativePhaseDiagnostics.makeContext(
                                runID: "run", lane: "render.\(lane)", segmentIndex: lane)
                            let span = TuringQwenNativePhaseDiagnostics.begin("ChildScope", context: context)
                            await Task.yield()
                            TuringQwenNativePhaseDiagnostics.end(span)
                        }
                    }
                }
            }
        }
        let report = recorder.snapshot()
        #expect(report.scopes.count == 2)
        #expect(Set(report.scopes.map { $0.context.lane }) == ["render.0", "render.1"])
        #expect(report.pendingScopeCount == 0)
        #expect(TuringQwenNativePhaseDiagnostics.recordingSession == nil)
    }
}
