import Foundation

struct TuringQwenMemorySoakReport: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let startedAt: Date
    let finishedAt: Date
    let generatedSegmentCount: Int
    let failedSegmentCount: Int
    let persistentAudioCacheUsed: Bool
    let transientAudioFilesRemaining: Int
    let synthesisSessionCreatedCount: Int
    let synthesisSessionReleasedCount: Int
    let cancelledSessionReleased: Bool
    let failedSessionReleased: Bool
    let sustainedMemorySlope: Bool
    let snapshots: [TuringMemorySnapshot]
}

actor TuringQwenMemorySoakReportWriter {
    private let rootURL: URL

    init(
        rootURL: URL
    ) {
        self.rootURL = rootURL
    }

    static func defaultWriter() throws -> TuringQwenMemorySoakReportWriter {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "TuringReports",
            isDirectory: true
        )

        return TuringQwenMemorySoakReportWriter(
            rootURL: root
        )
    }

    func write(
        _ report: TuringQwenMemorySoakReport
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let fileName = "qwen-memory-soak-\(Int(report.finishedAt.timeIntervalSince1970)).json"
        let url = rootURL.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(
            to: url,
            options: [.atomic]
        )

        print(
            """
            [TuringSoak] Qwen no-cache memory soak report written
              path: \(url.path)
            """
        )

        return url
    }
}
