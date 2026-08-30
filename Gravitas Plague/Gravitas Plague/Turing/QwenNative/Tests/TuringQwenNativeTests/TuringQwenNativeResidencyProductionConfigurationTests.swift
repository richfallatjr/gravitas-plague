import Testing

@testable import TuringQwenNative

struct TuringQwenNativeResidencyProductionConfigurationTests {
    @Test
    func shippingModesRemainExactTwoAndControlIsNotShipping() {
        #expect(TuringQwenNativeResidencyMode.independentFresh2.isShippingTopology)
        #expect(TuringQwenNativeResidencyMode.sharedImmutableFresh2.isShippingTopology)
        #expect(TuringQwenNativeResidencyMode.independentFresh2.laneCount == 2)
        #expect(TuringQwenNativeResidencyMode.sharedImmutableFresh2.laneCount == 2)
        #expect(!TuringQwenNativeResidencyMode.singleLaneSharedControl.isShippingTopology)
        #expect(TuringQwenNativeResidencyMode.singleLaneSharedControl.laneCount == 1)
    }
}
