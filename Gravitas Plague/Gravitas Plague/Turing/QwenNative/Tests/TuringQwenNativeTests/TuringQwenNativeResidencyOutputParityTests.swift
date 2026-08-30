import Testing

@testable import TuringQwenNative

struct TuringQwenNativeResidencyOutputParityTests {
    @Test
    func residencyModeDoesNotEnterSamplingSeedIdentity() {
        let first = TuringQwenNativeSamplingSeed.make(
            voiceID: "big_mike",
            runID: "run",
            segmentIndex: 4
        )
        let second = TuringQwenNativeSamplingSeed.make(
            voiceID: "big_mike",
            runID: "run",
            segmentIndex: 4
        )
        #expect(first == second)
    }
}
