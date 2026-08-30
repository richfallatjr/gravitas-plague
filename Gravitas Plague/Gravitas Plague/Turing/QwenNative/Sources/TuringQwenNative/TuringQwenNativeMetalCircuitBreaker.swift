import Foundation

public actor TuringQwenNativeMetalCircuitBreaker {
    public static let shared = TuringQwenNativeMetalCircuitBreaker()

    public enum State: Sendable, Equatable {
        case healthy(generation: TuringQwenNativeRecoveryGeneration)
        case recovering(TuringQwenNativeMetalFailure)
        case unavailable(TuringQwenNativeRecoveryUnavailableReason)
    }

    private let recovery: TuringQwenNativeRecoveryCoordinator

    public init(
        recovery: TuringQwenNativeRecoveryCoordinator = .shared
    ) {
        self.recovery = recovery
    }

    public func requireHealthy() async throws {
        try await recovery.requireReady()
    }

    public func trip(
        _ failure: TuringQwenNativeMetalFailure,
        generation: TuringQwenNativeRecoveryGeneration = .initial
    ) async {
        await recovery.recordFirstFailure(
            failure,
            generation: generation
        )
    }

    public func beginAfterOwnershipRelease(
        receipt: TuringQwenNativeRecoveryReleaseReceipt,
        baselineActiveBytes: UInt64
    ) async {
        await recovery.beginAfterOwnershipRelease(
            receipt: receipt,
            baselineActiveBytes: baselineActiveBytes
        )
    }

    public func snapshot() async -> State {
        switch await recovery.currentState() {
        case .ready(let generation), .readyForFreshRuntime(let generation):
            return .healthy(generation: generation)
        case .failing(let context), .draining(let context),
             .resettingMetal(let context):
            return .recovering(context.failure)
        case .probing(let context, _):
            return .recovering(context.failure)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .shuttingDown:
            return .unavailable(.shutdownDuringRecovery)
        }
    }

    #if DEBUG
    func resetForTesting() async {
        await recovery.resetForTesting()
    }
    #endif
}
