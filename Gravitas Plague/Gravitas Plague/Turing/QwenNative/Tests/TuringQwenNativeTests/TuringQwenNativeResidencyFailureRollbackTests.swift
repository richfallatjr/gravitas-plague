import Testing

@testable import TuringQwenNative

struct TuringQwenNativeResidencyFailureRollbackTests {
    @Test
    func shippingPoolRejectsFallbackAndReducedLaneTopology() {
        #expect(throws: (any Error).self) {
            _ = try TuringQwenNativeFreshInstancePool(
                requestedInstanceCount: 2,
                fallbackAllowed: true
            )
        }
        #expect(throws: (any Error).self) {
            _ = try TuringQwenNativeFreshInstancePool(
                requestedInstanceCount: 1,
                residencyMode: .sharedImmutableFresh2
            )
        }
    }
}
