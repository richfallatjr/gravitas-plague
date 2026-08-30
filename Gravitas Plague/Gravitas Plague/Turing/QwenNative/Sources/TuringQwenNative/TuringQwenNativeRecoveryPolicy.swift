import Foundation

public struct TuringQwenNativeRecoveryPolicy: Sendable, Equatable {
    public enum LowLevelMode: String, Codable, Sendable {
        case failSoftUnavailable
        case resetStreamsThenProbe
    }

    public let lowLevelMode: LowLevelMode
    public let maximumAttemptsPerFailure: Int
    public let maximumAttemptsPerLaunch: Int
    public let ownershipDrainTimeout: Duration
    public let metalDrainTimeout: Duration
    public let probeTimeout: Duration
    public let totalTimeout: Duration
    public let residualActiveToleranceBytes: UInt64

    public static var production: Self {
        #if GR_TURING_METAL_STREAM_RECOVERY
        let lowLevelMode: LowLevelMode = .resetStreamsThenProbe
        #else
        let lowLevelMode: LowLevelMode = .failSoftUnavailable
        #endif
        return Self(
            lowLevelMode: lowLevelMode,
            maximumAttemptsPerFailure: 1,
            maximumAttemptsPerLaunch: 3,
            ownershipDrainTimeout: .seconds(5),
            metalDrainTimeout: .seconds(5),
            probeTimeout: .seconds(2),
            totalTimeout: .seconds(12),
            residualActiveToleranceBytes: 128 * 1_024 * 1_024
        )
    }

    public static var qualification: Self {
        Self(
            lowLevelMode: .resetStreamsThenProbe,
            maximumAttemptsPerFailure: 1,
            maximumAttemptsPerLaunch: 12,
            ownershipDrainTimeout: .seconds(5),
            metalDrainTimeout: .seconds(5),
            probeTimeout: .seconds(2),
            totalTimeout: .seconds(12),
            residualActiveToleranceBytes: 128 * 1_024 * 1_024
        )
    }

    public static var current: Self {
        #if GR_TURING_METAL_RECOVERY_QUALIFICATION
        .qualification
        #else
        .production
        #endif
    }
}
