import Testing

@testable import TuringQwenNative

struct TuringQwenNativeTargetedBoundaryPolicyTests {
    @Test
    func noTargetedBoundaryIsTheDefaultContract() {
        #expect(TuringQwenNativeTargetedBoundaryPolicy.allCases == [
            .none,
            .dynamicRowCheckpoint,
            .codePredictorGroup,
            .decoderStage,
        ])
    }
}
