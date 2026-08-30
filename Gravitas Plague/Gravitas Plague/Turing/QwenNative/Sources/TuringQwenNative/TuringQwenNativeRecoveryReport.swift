import Foundation

public struct TuringQwenNativeRecoveryTransition: Codable, Sendable {
    public let state: String
    public let uptimeNanoseconds: UInt64
}

public struct TuringQwenNativeRecoveryMemoryReport: Codable, Sendable {
    public let baselineActiveBytes: UInt64
    public let activeBytesAfterOwnershipRelease: UInt64?
    public let cacheBytesAfterOwnershipRelease: UInt64?
    public let finalActiveBytes: UInt64?
    public let finalCacheBytes: UInt64?
    public let finalPeakBytes: UInt64?
}

public struct TuringQwenNativeRecoveryReport: Codable, Sendable {
    public let schemaVersion: Int
    public let recoveryID: UUID
    public let originalRunID: String
    public let originalGeneration: UInt64
    public let candidateGeneration: UInt64?
    public let finalGeneration: UInt64?
    public let firstFailureEpoch: UInt64
    public let firstFailedCommandBufferID: UInt64
    public let failurePhase: String?
    public let failureStage: String?
    public let failureLane: Int?
    public let failureSegment: Int?
    public let failureDecodeID: Int?
    public let attemptForFailure: Int
    public let attemptForLaunch: Int
    public let transitions: [TuringQwenNativeRecoveryTransition]
    public let laneReleaseReceipts: [TuringQwenNativeLaneReleaseReceipt]
    public let decoderReleaseReceipt: TuringQwenNativeDecoderReleaseReceipt?
    public let admissionReleaseReceipt: TuringQwenNativeAdmissionReleaseReceipt?
    public let MLXInFlightAtTransitions: [String: UInt64]
    public let streamResetCount: UInt64
    public let queueRecreationCount: UInt64
    public let probeCommandBufferID: UInt64?
    public let probeResult: String?
    public let memory: TuringQwenNativeRecoveryMemoryReport
    public let result: String
    public let unavailableReason: String?
}

enum TuringQwenNativeRecoveryReportWriter {
    private static let maximumHistoryBytes = 512 * 1_024

    static func persist(_ report: TuringQwenNativeRecoveryReport) {
        Task.detached(priority: .utility) {
            do {
                let manager = FileManager.default
                let support = try manager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let directory = support.appendingPathComponent(
                    "TuringDiagnostics",
                    isDirectory: true
                )
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                try data.write(
                    to: directory.appendingPathComponent(
                        "turing-mlx-recovery-last.json"
                    ),
                    options: [.atomic]
                )

                let compact = JSONEncoder()
                compact.outputFormatting = [.sortedKeys]
                var line = try compact.encode(report)
                line.append(0x0A)
                let history = directory.appendingPathComponent(
                    "turing-mlx-recovery-history.jsonl"
                )
                var bounded = (try? Data(contentsOf: history)) ?? Data()
                bounded.append(line)
                if bounded.count > maximumHistoryBytes {
                    let suffix = bounded.suffix(maximumHistoryBytes)
                    if let newline = suffix.firstIndex(of: 0x0A) {
                        bounded = Data(suffix[suffix.index(after: newline)...])
                    } else {
                        bounded = Data(suffix)
                    }
                }
                try bounded.write(to: history, options: [.atomic])
            } catch {
                TuringQwenNativeDiagnostics.recordBreadcrumb(
                    "qwen.recovery.reportWriteFailed",
                    details: ["error": error.localizedDescription]
                )
            }
        }
    }
}
