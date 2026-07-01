import Foundation

typealias FreshFoundationQueryRunner = TuringFoundationModelsRunner

actor FoundationConcurrencyLimiter {
    private let maxPermits: Int
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxPermits: Int) {
        let permits = max(1, maxPermits)
        self.maxPermits = permits
        self.availablePermits = permits
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            availablePermits = min(maxPermits, availablePermits + 1)
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
