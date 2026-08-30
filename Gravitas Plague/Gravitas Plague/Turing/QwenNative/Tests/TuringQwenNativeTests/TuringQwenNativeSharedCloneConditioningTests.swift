import Testing

@testable import TuringQwenNative

struct TuringQwenNativeSharedCloneConditioningTests {
    @Test
    func variantMismatchRejectsBeforeArtifactIO() {
        #expect(throws: (any Error).self) {
            _ = try TuringQwenNativeSharedCloneConditioning(
                profile: phase3CloneProfile(),
                variantID: "wrong"
            )
        }
    }
}
