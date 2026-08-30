import Testing

@testable import TuringQwenNative

struct TuringQwenNativeMLXErrorBoundaryTests {
    private struct FixtureError: Error {}

    @Test
    func ordinarySwiftErrorPassesThroughWithoutTrippingMetalMapping() {
        let context = TuringQwenNativeMLXExecutionContext(
            runID: "boundary-test",
            instanceID: .init(index: 0),
            segmentIndex: 3,
            laneIndex: 1,
            phase: .dynamicTalker,
            stage: "fixture"
        )
        #expect(throws: FixtureError.self) {
            try TuringQwenNativeMLXErrorBoundary.run(context: context) {
                throw FixtureError()
            }
        }
    }
}
