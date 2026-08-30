import Foundation

public enum TuringQwenNativeRecoveryUnavailableReason:
    String,
    Codable,
    Sendable,
    Equatable
{
    case productionRecoveryUnqualified
    case launchAttemptBudgetExceeded
    case ownershipDrainTimedOut
    case metalDrainTimedOut
    case residencyLeak
    case streamResetFailed
    case healthProbeFailed
    case appBackgroundedDuringRecovery
    case shutdownDuringRecovery
    case lowLevelRecoveryRejected
}

public struct TuringQwenNativeRecoveryFailureContext: Sendable, Equatable {
    public let recoveryID: UUID
    public let originalGeneration: TuringQwenNativeRecoveryGeneration
    public let failure: TuringQwenNativeMetalFailure
    public let firstFailureUptimeNanoseconds: UInt64
    public let attemptNumberForLaunch: Int
}

public enum TuringQwenNativeRecoveryState: Sendable, Equatable {
    case ready(generation: TuringQwenNativeRecoveryGeneration)
    case failing(TuringQwenNativeRecoveryFailureContext)
    case draining(TuringQwenNativeRecoveryFailureContext)
    case resettingMetal(TuringQwenNativeRecoveryFailureContext)
    case probing(
        context: TuringQwenNativeRecoveryFailureContext,
        candidateGeneration: TuringQwenNativeRecoveryGeneration
    )
    case readyForFreshRuntime(generation: TuringQwenNativeRecoveryGeneration)
    case unavailable(TuringQwenNativeRecoveryUnavailableReason)
    case shuttingDown
}

public enum TuringQwenNativeRecoveryOutcome: Sendable, Equatable {
    case recovered(generation: TuringQwenNativeRecoveryGeneration)
    case unavailable(TuringQwenNativeRecoveryUnavailableReason)
}

public enum TuringQwenNativeRecoveryAvailability: Sendable, Equatable {
    case ready(generation: UInt64)
    case recovering
    case unavailableUntilRelaunch(
        reason: TuringQwenNativeRecoveryUnavailableReason
    )
}

public struct TuringQwenNativeRecoveryUnavailableError:
    Error,
    LocalizedError,
    Sendable
{
    public let availability: TuringQwenNativeRecoveryAvailability

    public var errorDescription: String? {
        switch availability {
        case .ready:
            return nil
        case .recovering:
            return "Turing Qwen recovery is in progress."
        case .unavailableUntilRelaunch(let reason):
            return "Turing Qwen is unavailable until relaunch (\(reason.rawValue))."
        }
    }
}
