import Testing

@testable import TuringQwenNative

struct TuringQwenNativeResidencyUnloadTests {
    @Test
    func leaseRegistryReachesZeroOnlyAfterBothLanesRelease() throws {
        var registry = TuringQwenNativeResidencyLeaseRegistry()
        let lane0 = TuringQwenNativeFreshInstanceID(index: 0)
        let lane1 = TuringQwenNativeFreshInstanceID(index: 1)
        let first = try registry.acquire(laneInstanceID: lane0)
        let second = try registry.acquire(laneInstanceID: lane1)
        try registry.release(leaseID: first, laneInstanceID: lane0)
        #expect(registry.count == 1)
        try registry.release(leaseID: second, laneInstanceID: lane1)
        #expect(registry.isEmpty)
    }
}
