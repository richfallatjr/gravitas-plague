import Testing

@testable import TuringQwenNative

struct TuringQwenNativeCommandBufferProfileTests {
    @Test
    func profileMatrixKeepsCrossedAndBalancedLimitsDistinct() {
        #expect(TuringQwenNativeCommandBufferProfile.allCases.count == 6)
        #expect(TuringQwenNativeCommandBufferProfile.deviceDefault.configuredOperations == nil)
        #expect(TuringQwenNativeCommandBufferProfile.operations32Megabytes40.configuredOperations == 32)
        #expect(TuringQwenNativeCommandBufferProfile.operations32Megabytes40.configuredMegabytes == 40)
        #expect(TuringQwenNativeCommandBufferProfile.operations40Megabytes32.configuredOperations == 40)
        #expect(TuringQwenNativeCommandBufferProfile.operations40Megabytes32.configuredMegabytes == 32)
        #expect(TuringQwenNativeCommandBufferProfile.operations24Megabytes24.configuredOperations == 24)
        #expect(TuringQwenNativeCommandBufferProfile.operations24Megabytes24.configuredMegabytes == 24)
    }
}
