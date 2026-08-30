import MLX
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeMetalCircuitBreakerTests {
    @Test
    func firstMetalFailureTripsUntilRelaunch() async throws {
        let breaker = TuringQwenNativeMetalCircuitBreaker()
        try await breaker.requireHealthy()
        let failure = TuringQwenNativeMetalFailure(
            record: .testing(commandBufferID: 17)
        )
        await breaker.trip(failure)
        await breaker.trip(TuringQwenNativeMetalFailure(
            record: .testing(commandBufferID: 99)
        ))

        let state = await breaker.snapshot()
        guard case .failedUntilRelaunch(let retained) = state else {
            Issue.record("Circuit breaker did not retain its failure.")
            return
        }
        #expect(retained.record.record.commandBufferID == 17)
        await #expect(throws: TuringQwenNativeMetalFailure.self) {
            try await breaker.requireHealthy()
        }
    }
}
