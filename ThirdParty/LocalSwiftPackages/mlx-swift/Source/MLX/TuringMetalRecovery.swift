import Cmlx
import Foundation

public struct TuringMetalRecoveryToken: Sendable, Hashable {
    public let high: UInt64
    public let low: UInt64

    fileprivate var cValue: mlx_turing_metal_recovery_token {
        .init(high: high, low: low)
    }
}

public enum TuringMetalRecoveryState: Int32, Sendable, Codable {
    case ready = 0
    case draining = 1
    case resetting = 2
    case probing = 3
    case unavailable = 4
}

public enum TuringMetalRecoveryResultCode: Int32, Sendable, Codable {
    case ok = 0
    case alreadyOwned = 1
    case staleFailure = 2
    case staleOwner = 3
    case drainTimedOut = 4
    case activeExecution = 5
    case inFlightBuffers = 6
    case residencyLeak = 7
    case resetFailed = 8
    case probeFailed = 9
    case unsupported = 10
    case unavailable = 11
}

public struct TuringMetalRecoverySnapshot: Sendable, Equatable, Codable {
    public let state: TuringMetalRecoveryState
    public let generation: UInt64
    public let activeFailureEpoch: UInt64
    public let activeExecutionCount: UInt64
    public let inFlightCommandBufferCount: UInt64
    public let streamResetCount: UInt64
    public let queueRecreationCount: UInt64
    public let lastProbeCommandBufferID: UInt64
    public let lastProbeStatus: Int32
    public let MLXActiveBytes: UInt64
    public let MLXCacheBytes: UInt64
    public let MLXPeakBytes: UInt64
    public let reason: String
}

public struct TuringMetalRecoveryBeginResult: Sendable {
    public let token: TuringMetalRecoveryToken
    public let snapshot: TuringMetalRecoverySnapshot
}

public struct TuringMetalRecoveryResetResult: Sendable, Equatable {
    public let oldGeneration: UInt64
    public let candidateGeneration: UInt64
    public let disposedStreamCount: UInt64
    public let recreatedQueueCount: UInt64
    public let activeBytesBefore: UInt64
    public let activeBytesAfter: UInt64
    public let cacheBytesBefore: UInt64
    public let cacheBytesAfter: UInt64
    public let snapshot: TuringMetalRecoverySnapshot
}

public struct TuringMetalRecoveryProbeResult: Sendable {
    public let resultCode: TuringMetalRecoveryResultCode
    public let candidateGeneration: UInt64
    public let commandBufferID: UInt64
    public let completionStatus: Int32
    public let metalErrorCode: Int32
    public let elapsedNanoseconds: UInt64
    public let readbackMatches: Bool
    public let snapshot: TuringMetalRecoverySnapshot

    fileprivate let cValue: mlx_turing_metal_recovery_probe_result
}

public struct TuringMetalRecoveryError: Error, LocalizedError, Sendable {
    public let operation: String
    public let resultCode: TuringMetalRecoveryResultCode
    public let snapshot: TuringMetalRecoverySnapshot?

    public var errorDescription: String? {
        "Turing Metal recovery \(operation) failed: " +
            "\(resultCode)\(snapshot.map { " (\($0.reason))" } ?? "")"
    }
}

public enum TuringMetalRecovery {
    public static func snapshot() throws -> TuringMetalRecoverySnapshot {
        var value = mlx_turing_metal_recovery_snapshot()
        let code = mlx_turing_metal_recovery_copy_snapshot(&value)
        try requireSuccess(code, operation: "snapshot", snapshot: value)
        return snapshot(from: value)
    }

    public static func begin(
        expectedFailureEpoch: UInt64,
        expectedGeneration: UInt64
    ) throws -> TuringMetalRecoveryBeginResult {
        var value = mlx_turing_metal_recovery_begin_result()
        let code = mlx_turing_metal_recovery_begin(
            expectedFailureEpoch,
            expectedGeneration,
            &value
        )
        try requireSuccess(
            code,
            operation: "begin",
            snapshot: value.snapshot
        )
        return .init(
            token: .init(high: value.token.high, low: value.token.low),
            snapshot: snapshot(from: value.snapshot)
        )
    }

    public static func waitForQuiescence(
        token: TuringMetalRecoveryToken,
        timeout: Duration
    ) throws -> TuringMetalRecoverySnapshot {
        var value = mlx_turing_metal_recovery_snapshot()
        let code = mlx_turing_metal_recovery_wait_for_quiescence(
            token.cValue,
            nanoseconds(timeout),
            &value
        )
        try requireSuccess(
            code,
            operation: "waitForQuiescence",
            snapshot: value
        )
        return snapshot(from: value)
    }

    public static func resetStreams(
        token: TuringMetalRecoveryToken,
        baselineActiveBytes: UInt64,
        residualToleranceBytes: UInt64
    ) throws -> TuringMetalRecoveryResetResult {
        var value = mlx_turing_metal_recovery_reset_result()
        let code = mlx_turing_metal_recovery_reset_streams(
            token.cValue,
            baselineActiveBytes,
            residualToleranceBytes,
            &value
        )
        try requireSuccess(
            code,
            operation: "resetStreams",
            snapshot: value.snapshot
        )
        return .init(
            oldGeneration: value.old_generation,
            candidateGeneration: value.candidate_generation,
            disposedStreamCount: value.disposed_stream_count,
            recreatedQueueCount: value.recreated_queue_count,
            activeBytesBefore: value.active_bytes_before,
            activeBytesAfter: value.active_bytes_after,
            cacheBytesBefore: value.cache_bytes_before,
            cacheBytesAfter: value.cache_bytes_after,
            snapshot: snapshot(from: value.snapshot)
        )
    }

    public static func runProbe(
        token: TuringMetalRecoveryToken,
        timeout: Duration
    ) throws -> TuringMetalRecoveryProbeResult {
        var value = mlx_turing_metal_recovery_probe_result()
        let code = mlx_turing_metal_recovery_run_probe(
            token.cValue,
            nanoseconds(timeout),
            &value
        )
        try requireSuccess(
            code,
            operation: "runProbe",
            snapshot: value.snapshot
        )
        return probe(from: value)
    }

    public static func finish(
        token: TuringMetalRecoveryToken,
        probe: TuringMetalRecoveryProbeResult
    ) throws -> TuringMetalRecoverySnapshot {
        var value = mlx_turing_metal_recovery_snapshot()
        let code = mlx_turing_metal_recovery_finish(
            token.cValue,
            probe.cValue,
            &value
        )
        try requireSuccess(code, operation: "finish", snapshot: value)
        return snapshot(from: value)
    }

    @discardableResult
    public static func markUnavailable(
        token: TuringMetalRecoveryToken,
        resultCode: TuringMetalRecoveryResultCode,
        reason: String
    ) throws -> TuringMetalRecoverySnapshot {
        var value = mlx_turing_metal_recovery_snapshot()
        let code = reason.withCString {
            mlx_turing_metal_recovery_mark_unavailable(
                token.cValue,
                resultCode.rawValue,
                $0,
                &value
            )
        }
        guard code == TuringMetalRecoveryResultCode.unavailable.rawValue else {
            try requireSuccess(
                code,
                operation: "markUnavailable",
                snapshot: value
            )
            return snapshot(from: value)
        }
        return snapshot(from: value)
    }

    #if DEBUG
    public static func resetForTesting() {
        mlx_turing_metal_recovery_test_reset()
    }
    #endif

    private static func requireSuccess(
        _ rawCode: Int32,
        operation: String,
        snapshot cSnapshot: mlx_turing_metal_recovery_snapshot
    ) throws {
        guard rawCode == TuringMetalRecoveryResultCode.ok.rawValue else {
            throw TuringMetalRecoveryError(
                operation: operation,
                resultCode: TuringMetalRecoveryResultCode(rawValue: rawCode)
                    ?? .unsupported,
                snapshot: snapshot(from: cSnapshot)
            )
        }
    }

    private static func probe(
        from value: mlx_turing_metal_recovery_probe_result
    ) -> TuringMetalRecoveryProbeResult {
        .init(
            resultCode: TuringMetalRecoveryResultCode(
                rawValue: value.result_code
            ) ?? .unsupported,
            candidateGeneration: value.candidate_generation,
            commandBufferID: value.command_buffer_id,
            completionStatus: value.completion_status,
            metalErrorCode: value.metal_error_code,
            elapsedNanoseconds: value.elapsed_nanoseconds,
            readbackMatches: value.readback_matches != 0,
            snapshot: snapshot(from: value.snapshot),
            cValue: value
        )
    }

    private static func snapshot(
        from value: mlx_turing_metal_recovery_snapshot
    ) -> TuringMetalRecoverySnapshot {
        .init(
            state: TuringMetalRecoveryState(rawValue: value.state)
                ?? .unavailable,
            generation: value.recovery_generation,
            activeFailureEpoch: value.active_failure_epoch,
            activeExecutionCount: value.active_execution_count,
            inFlightCommandBufferCount:
                value.in_flight_command_buffer_count,
            streamResetCount: value.stream_reset_count,
            queueRecreationCount: value.queue_recreation_count,
            lastProbeCommandBufferID: value.last_probe_command_buffer_id,
            lastProbeStatus: value.last_probe_status,
            MLXActiveBytes: value.mlx_active_bytes,
            MLXCacheBytes: value.mlx_cache_bytes,
            MLXPeakBytes: value.mlx_peak_bytes,
            reason: string(from: value.reason)
        )
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let subsecond = UInt64(max(0, components.attoseconds / 1_000_000_000))
        let (whole, overflow) = seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        return overflow ? UInt64.max : whole &+ subsecond
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            let buffer = bytes.bindMemory(to: CChar.self)
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base)
        }
    }
}
