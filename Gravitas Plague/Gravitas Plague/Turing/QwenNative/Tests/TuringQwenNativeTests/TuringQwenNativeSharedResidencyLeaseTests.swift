import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeSharedResidencyLeaseTests {
    @Test
    func registryAllowsExactlyTwoUniqueLanesAndRejectsStaleRelease() throws {
        var registry = TuringQwenNativeResidencyLeaseRegistry()
        let lane0 = TuringQwenNativeFreshInstanceID(index: 0)
        let lane1 = TuringQwenNativeFreshInstanceID(index: 1)
        let first = try registry.acquire(laneInstanceID: lane0)
        let second = try registry.acquire(laneInstanceID: lane1)
        #expect(registry.count == 2)
        #expect(throws: (any Error).self) {
            try registry.acquire(laneInstanceID: .init(index: 2))
        }
        try registry.release(leaseID: first, laneInstanceID: lane0)
        #expect(throws: (any Error).self) {
            try registry.release(leaseID: first, laneInstanceID: lane0)
        }
        #expect(registry.count == 1)
        try registry.release(leaseID: second, laneInstanceID: lane1)
        #expect(registry.isEmpty)
    }

    @Test
    func duplicateLaneIsRejected() throws {
        var registry = TuringQwenNativeResidencyLeaseRegistry()
        let lane = TuringQwenNativeFreshInstanceID(index: 0)
        _ = try registry.acquire(laneInstanceID: lane)
        #expect(throws: (any Error).self) {
            try registry.acquire(laneInstanceID: lane)
        }
    }
}
