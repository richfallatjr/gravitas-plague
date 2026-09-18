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
}
