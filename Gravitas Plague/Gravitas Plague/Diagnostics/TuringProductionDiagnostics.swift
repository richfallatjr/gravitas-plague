import Foundation
import MetricKit
import OSLog

#if canImport(UIKit)
import UIKit
#endif

struct TuringProductionDiagnosticMemory: Codable, Sendable {
    let availableProcessMemoryBytes: UInt64
    let physicalFootprintBytes: UInt64
    let residentSizeBytes: UInt64
    let mlxActiveMemoryBytes: Int
    let mlxCacheMemoryBytes: Int
    let mlxPeakMemoryBytes: Int
    let mlxCacheLimitBytes: Int
    let mlxMemoryLimitBytes: Int
}

struct TuringProductionDiagnosticEvent: Codable, Sendable {
    let schemaVersion: Int
    let eventID: UUID
    let launchID: UUID
    let timestamp: Date
    let systemUptimeSeconds: TimeInterval
    let kind: String
    let label: String
    let runID: String?
    let segmentIndex: Int?
    let memory: TuringProductionDiagnosticMemory?
    let details: [String: String]
}

enum TuringProductionDiagnostics {
    private static let launchID = UUID()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gravitas.plague",
        category: "TuringProduction"
    )
    private static let writer = try? TuringPersistentDiagnosticWriter(
        launchID: launchID
    )
    private static let lifecycleMonitor = TuringDiagnosticLifecycleMonitor()

    static var shouldOfferExport: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func start() {
        let info = Bundle.main.infoDictionary
        record(
            kind: "application",
            label: "launch",
            details: [
                "appVersion": info?["CFBundleShortVersionString"] as? String
                    ?? "unknown",
                "buildVersion": info?["CFBundleVersion"] as? String
                    ?? "unknown",
                "operatingSystemVersion": ProcessInfo.processInfo
                    .operatingSystemVersionString
            ]
        )
        lifecycleMonitor.start()
        TuringMetricKitCollector.shared.start()
    }

    static func recordMemory(
        _ snapshot: TuringMemoryBudgetSnapshot,
        runID: String? = nil,
        segmentIndex: Int? = nil,
        details: [String: String] = [:]
    ) {
        let memory = TuringProductionDiagnosticMemory(
            availableProcessMemoryBytes:
                snapshot.availableProcessMemoryBytes,
            physicalFootprintBytes: snapshot.physicalFootprintBytes,
            residentSizeBytes: snapshot.residentSizeBytes,
            mlxActiveMemoryBytes: snapshot.mlxActiveMemoryBytes,
            mlxCacheMemoryBytes: snapshot.mlxCacheMemoryBytes,
            mlxPeakMemoryBytes: snapshot.mlxPeakMemoryBytes,
            mlxCacheLimitBytes: snapshot.mlxCacheLimitBytes,
            mlxMemoryLimitBytes: snapshot.mlxMemoryLimitBytes
        )
        var mergedDetails = details
        if let modelID = snapshot.activeQwenModelID {
            mergedDetails["activeQwenModelID"] = modelID
        }
        if let quantization = snapshot.quantization {
            mergedDetails["quantization"] = quantization
        }
        mergedDetails["increasedMemoryEntitlement"] =
            snapshot.increasedMemoryEntitlementStatus

        record(
            kind: "memory",
            label: snapshot.label,
            runID: runID,
            segmentIndex: segmentIndex,
            memory: memory,
            details: mergedDetails
        )
    }

    static func recordSignal(
        _ label: String,
        details: [String: String] = [:]
    ) {
        record(
            kind: "systemSignal",
            label: label,
            details: details
        )
    }

    static func makeExportFile() throws -> URL {
        guard let writer else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try writer.makeExportFile()
    }

    fileprivate static func persistMetricKitPayload(
        _ data: Data,
        index: Int
    ) {
        guard let url = try? writer?.writeAttachment(
            data,
            fileName: "metrickit-diagnostic-\(Int(Date().timeIntervalSince1970))-\(index).json"
        ) else {
            return
        }
        record(
            kind: "metrickit",
            label: "diagnosticPayloadReceived",
            details: ["file": url.lastPathComponent]
        )
    }

    private static func record(
        kind: String,
        label: String,
        runID: String? = nil,
        segmentIndex: Int? = nil,
        memory: TuringProductionDiagnosticMemory? = nil,
        details: [String: String] = [:]
    ) {
        let event = TuringProductionDiagnosticEvent(
            schemaVersion: 1,
            eventID: UUID(),
            launchID: launchID,
            timestamp: Date(),
            systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
            kind: kind,
            label: label,
            runID: runID,
            segmentIndex: segmentIndex,
            memory: memory,
            details: details
        )
        writer?.append(event)

        if let memory {
            logger.notice(
                "label=\(label, privacy: .public) footprintMB=\(memory.physicalFootprintBytes / 1_048_576, privacy: .public) availableMB=\(memory.availableProcessMemoryBytes / 1_048_576, privacy: .public) mlxActiveMB=\(memory.mlxActiveMemoryBytes / 1_048_576, privacy: .public) mlxCacheMB=\(memory.mlxCacheMemoryBytes / 1_048_576, privacy: .public)"
            )
        } else {
            logger.notice(
                "kind=\(kind, privacy: .public) label=\(label, privacy: .public)"
            )
        }
    }
}

private final class TuringPersistentDiagnosticWriter: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.gravitas.turing.production-diagnostics"
    )
    private let rootURL: URL
    private let logURL: URL
    private let handle: FileHandle

    init(launchID: UUID) throws {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("TuringDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var excludedRoot = root
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedRoot.setResourceValues(resourceValues)

        let url = root.appendingPathComponent(
            "turing-launch-\(Int(Date().timeIntervalSince1970))-\(launchID.uuidString).jsonl"
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)

        self.rootURL = root
        self.logURL = url
        self.handle = try FileHandle(forWritingTo: url)
        pruneOldArtifacts()
    }

    deinit {
        try? handle.close()
    }

    func append(_ event: TuringProductionDiagnosticEvent) {
        queue.sync {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                var data = try encoder.encode(event)
                data.append(0x0A)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                print(
                    "[TuringProductionDiagnostics] write failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func writeAttachment(_ data: Data, fileName: String) throws -> URL {
        try queue.sync {
            let url = rootURL.appendingPathComponent(fileName)
            try data.write(to: url, options: [.atomic])
            return url
        }
    }

    func makeExportFile() throws -> URL {
        try queue.sync {
            try handle.synchronize()
            let artifacts = try diagnosticArtifacts()
            let exportURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Gravitas-Turing-Diagnostics.txt")
            var export = Data(
                "Gravitas Plague Turing diagnostics\nGenerated: \(Date())\n\n"
                    .utf8
            )
            for artifact in artifacts {
                export.append(
                    Data(
                        "===== \(artifact.lastPathComponent) =====\n".utf8
                    )
                )
                export.append(try Data(contentsOf: artifact))
                export.append(Data("\n\n".utf8))
            }
            try export.write(to: exportURL, options: [.atomic])
            return exportURL
        }
    }

    private func diagnosticArtifacts() throws -> [URL] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey
        ]
        return try FileManager.default
            .contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                let values = try? url.resourceValues(forKeys: keys)
                return values?.isRegularFile == true
            }
            .sorted { lhs, rhs in
                let left = try? lhs.resourceValues(forKeys: keys)
                    .contentModificationDate
                let right = try? rhs.resourceValues(forKeys: keys)
                    .contentModificationDate
                return (left ?? .distantPast) < (right ?? .distantPast)
            }
    }

    private func pruneOldArtifacts() {
        guard let artifacts = try? diagnosticArtifacts(),
              artifacts.count > 16 else {
            return
        }
        for url in artifacts.dropLast(16) where url != logURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private final class TuringDiagnosticLifecycleMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard started == false else { return }
        started = true

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                let state = ProcessInfo.processInfo.thermalState
                TuringProductionDiagnostics.recordSignal(
                    "thermalStateChanged",
                    details: ["thermalState": String(state.rawValue)]
                )
                TuringMemoryBudgetProbe.log(
                    label: "thermalStateChanged.\(state.rawValue)"
                )
            }
        )

        #if canImport(UIKit)
        observers.append(
            center.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { _ in
                TuringProductionDiagnostics.recordSignal(
                    "didReceiveMemoryWarning"
                )
                TuringMemoryBudgetProbe.log(
                    label: "didReceiveMemoryWarning"
                )
            }
        )
        #endif
    }
}

private final class TuringMetricKitCollector:
    NSObject,
    MXMetricManagerSubscriber,
    @unchecked Sendable
{
    static let shared = TuringMetricKitCollector()

    private let lock = NSLock()
    private var started = false

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard started == false else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for (index, payload) in payloads.enumerated() {
            TuringProductionDiagnostics.persistMetricKitPayload(
                payload.jsonRepresentation(),
                index: index
            )
        }
    }
}
