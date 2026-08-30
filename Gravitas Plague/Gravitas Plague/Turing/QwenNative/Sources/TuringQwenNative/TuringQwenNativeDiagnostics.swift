import Foundation
import MLX
import OSLog

public struct TuringQwenNativeMemorySnapshot: Codable, Sendable, Equatable {
    public let activeMemoryBytes: Int
    public let cacheMemoryBytes: Int
    public let peakMemoryBytes: Int
    public let cacheLimitBytes: Int
    public let memoryLimitBytes: Int

    public init(
        activeMemoryBytes: Int,
        cacheMemoryBytes: Int,
        peakMemoryBytes: Int,
        cacheLimitBytes: Int,
        memoryLimitBytes: Int
    ) {
        self.activeMemoryBytes = activeMemoryBytes
        self.cacheMemoryBytes = cacheMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.cacheLimitBytes = cacheLimitBytes
        self.memoryLimitBytes = memoryLimitBytes
    }
}

/// A deliberately small public bridge from the app's durable diagnostics into
/// MLX. It does not retain arrays, model state, or the snapshot returned by MLX.
public enum TuringQwenNativeDiagnostics {
    private static let logger = Logger(
        subsystem: "com.gravitas.turing",
        category: "QwenNativeBreadcrumb"
    )
    private static let breadcrumbWriter =
        TuringQwenNativeCrashBreadcrumbWriter()

    public static func memorySnapshot() -> TuringQwenNativeMemorySnapshot {
        let snapshot = Memory.snapshot()
        return TuringQwenNativeMemorySnapshot(
            activeMemoryBytes: snapshot.activeMemory,
            cacheMemoryBytes: snapshot.cacheMemory,
            peakMemoryBytes: snapshot.peakMemory,
            cacheLimitBytes: Memory.cacheLimit,
            memoryLimitBytes: Memory.memoryLimit
        )
    }

    public static func recordBreadcrumb(
        _ label: String,
        runID: String? = nil,
        instanceID: String? = nil,
        segmentIndex: Int? = nil,
        details: [String: String] = [:]
    ) {
        // The package's macOS target exists for host-side contract tests. MLX
        // attempts to load its default Metal library when queried there, which
        // is not available in that test process. Runtime Turing is visionOS-only.
        #if os(visionOS)
        let mlx = memorySnapshot()
        #else
        let mlx = TuringQwenNativeMemorySnapshot(
            activeMemoryBytes: 0,
            cacheMemoryBytes: 0,
            peakMemoryBytes: 0,
            cacheLimitBytes: 0,
            memoryLimitBytes: 0
        )
        #endif
        let process = TuringQwenNativeProcessMemoryProbe.snapshot()
        let breadcrumb = TuringQwenNativeCrashBreadcrumb(
            schemaVersion: 1,
            timestamp: Date(),
            systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
            label: label,
            runID: runID,
            instanceID: instanceID,
            segmentIndex: segmentIndex,
            mlx: mlx,
            physicalFootprintMB: process.physFootprintMB,
            residentSizeMB: process.residentSizeMB,
            availableProcessMemoryMB: process.availableProcessMemoryMB,
            details: details
        )
        breadcrumbWriter.write(breadcrumb)
        logger.notice(
            "label=\(label, privacy: .public) runID=\(runID ?? "none", privacy: .public) segmentIndex=\(segmentIndex ?? -1, privacy: .public) footprintMB=\(process.physFootprintMB, privacy: .public) mlxActiveMB=\(mlx.activeMemoryBytes / 1_048_576, privacy: .public)"
        )
    }

    public static func recordResidencyEvent(
        _ label: String,
        ownerID: UUID? = nil,
        runID: String? = nil,
        instanceID: String? = nil,
        details: [String: String] = [:]
    ) {
        var residencyDetails = details
        if let ownerID {
            residencyDetails["residencyOwnerID"] = ownerID.uuidString
        }
        recordBreadcrumb(
            label,
            runID: runID,
            instanceID: instanceID,
            details: residencyDetails
        )
    }
}

private struct TuringQwenNativeCrashBreadcrumb: Codable, Sendable {
    let schemaVersion: Int
    let timestamp: Date
    let systemUptimeSeconds: TimeInterval
    let label: String
    let runID: String?
    let instanceID: String?
    let segmentIndex: Int?
    let mlx: TuringQwenNativeMemorySnapshot
    let physicalFootprintMB: Double
    let residentSizeMB: Double
    let availableProcessMemoryMB: Double
    let details: [String: String]
}

private final class TuringQwenNativeCrashBreadcrumbWriter:
    @unchecked Sendable
{
    private static let maximumTimelineBytes = 1_048_576
    private let lock = NSLock()
    private let url: URL?
    private let timelineURL: URL?

    init() {
        guard let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            url = nil
            timelineURL = nil
            return
        }
        let root = applicationSupport.appendingPathComponent(
            "TuringDiagnostics",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var excludedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excludedRoot.setResourceValues(values)
        url = root.appendingPathComponent(
            "qwen-native-last-breadcrumb.json"
        )
        timelineURL = root.appendingPathComponent(
            "qwen-native-timeline.jsonl"
        )
    }

    func write(_ breadcrumb: TuringQwenNativeCrashBreadcrumb) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(breadcrumb)
            try encoded.write(
                to: url,
                options: [.atomic]
            )
            try appendToBoundedTimeline(encoded)
        } catch {
            print(
                "[TuringQwenNativeDiagnostics] breadcrumb write failed: \(error.localizedDescription)"
            )
        }
    }

    private func appendToBoundedTimeline(_ encoded: Data) throws {
        guard let timelineURL else { return }
        var line = encoded
        line.append(0x0A)

        let existingBytes = (
            try? timelineURL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
        ) ?? 0
        if existingBytes + line.count > Self.maximumTimelineBytes {
            try line.write(to: timelineURL, options: [.atomic])
            return
        }
        guard FileManager.default.fileExists(atPath: timelineURL.path) else {
            try line.write(to: timelineURL, options: [.atomic])
            return
        }

        let handle = try FileHandle(forWritingTo: timelineURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
