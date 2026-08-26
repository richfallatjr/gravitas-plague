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
        let mlx = memorySnapshot()
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
            details: details
        )
        breadcrumbWriter.write(breadcrumb)
        logger.notice(
            "label=\(label, privacy: .public) runID=\(runID ?? "none", privacy: .public) segmentIndex=\(segmentIndex ?? -1, privacy: .public) footprintMB=\(process.physFootprintMB, privacy: .public) mlxActiveMB=\(mlx.activeMemoryBytes / 1_048_576, privacy: .public)"
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
    let details: [String: String]
}

private final class TuringQwenNativeCrashBreadcrumbWriter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let url: URL?

    init() {
        guard let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            url = nil
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
    }

    func write(_ breadcrumb: TuringQwenNativeCrashBreadcrumb) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(breadcrumb).write(
                to: url,
                options: [.atomic]
            )
        } catch {
            print(
                "[TuringQwenNativeDiagnostics] breadcrumb write failed: \(error.localizedDescription)"
            )
        }
    }
}
