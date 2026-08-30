import MLX
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeMetalCircuitBreakerTests {
    @Test
    func firstMetalFailureIsRecordedAndAdmissionCloses() async throws {
        let recovery = TuringQwenNativeRecoveryCoordinator(
            policy: .production
        )
        let breaker = TuringQwenNativeMetalCircuitBreaker(
            recovery: recovery
        )
        try await breaker.requireHealthy()
        let failure = TuringQwenNativeMetalFailure(
            record: .testing(commandBufferID: 17)
        )
        await breaker.trip(failure)
        await breaker.trip(TuringQwenNativeMetalFailure(
            record: .testing(commandBufferID: 99)
        ))

        let state = await breaker.snapshot()
        guard case .recovering(let retained) = state else {
            Issue.record("Circuit breaker did not retain its failure.")
            return
        }
        #expect(retained.record.record.commandBufferID == failure.record.record.commandBufferID)
        do {
            try await breaker.requireHealthy()
            Issue.record("Recovery admission remained open after failure.")
        } catch {
            #expect(error is TuringQwenNativeRecoveryUnavailableError)
        }
    }
}
