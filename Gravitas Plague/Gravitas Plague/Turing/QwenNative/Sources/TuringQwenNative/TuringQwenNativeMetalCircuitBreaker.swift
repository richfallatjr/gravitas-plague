import Foundation

public actor TuringQwenNativeMetalCircuitBreaker {
    public static let shared = TuringQwenNativeMetalCircuitBreaker()

    public enum State: Sendable, Equatable {
        case healthy
        case failedUntilRelaunch(TuringQwenNativeMetalFailure)
    }

    private var state: State = .healthy

    public init() {}

    public func requireHealthy() throws {
        if case .failedUntilRelaunch(let failure) = state {
            throw failure
        }
    }

    public func trip(_ failure: TuringQwenNativeMetalFailure) {
        guard case .healthy = state else { return }
        state = .failedUntilRelaunch(failure)
    }

    public func snapshot() -> State {
        state
    }

    #if DEBUG
    func resetForTesting() {
        state = .healthy
    }
    #endif
}
