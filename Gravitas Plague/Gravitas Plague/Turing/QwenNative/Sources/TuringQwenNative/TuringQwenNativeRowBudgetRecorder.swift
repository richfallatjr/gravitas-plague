import Foundation

struct TuringQwenNativeRowBudgetRecorder: Sendable {
    private let url: URL

    init() throws {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("TuringQwenNativeHello", isDirectory: true)

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        self.url = root.appendingPathComponent("row-budget-last-run.json")
    }

    func logPreviousRunIfNeeded(prefix: String) {
        guard let record = readRecord(),
              record.finished == false else {
            return
        }

        print("""
        \(prefix) previous row-budget run likely exceeded process memory
          memoryLabel: \(record.memoryLabel)
          targetRows: \(record.targetRows)
          lastStartedRowIndex: \(record.lastStartedRowIndex.map(String.init) ?? "nil")
          completedRows: \(record.completedRows)
          inferredSafeRows: \(record.completedRows)
          estimatedSafeSeconds: \(String(format: "%.3f", Self.estimatedAudioSeconds(rows: record.completedRows)))
        """)
    }

    func started(
        targetRows: Int,
        memoryLabel: String
    ) {
        write(
            Record(
                memoryLabel: memoryLabel,
                targetRows: targetRows,
                lastStartedRowIndex: nil,
                completedRows: 0,
                finished: false,
                startedAt: Date(),
                finishedAt: nil
            )
        )
    }

    func startedRow(
        _ rowIndex: Int
    ) {
        var record = readRecord() ?? Record.empty
        record.lastStartedRowIndex = rowIndex
        record.finished = false
        write(record)
    }

    func completedRows(
        _ rowCount: Int
    ) {
        var record = readRecord() ?? Record.empty
        record.completedRows = rowCount
        record.finished = false
        write(record)
    }

    func finished(
        completedRows rowCount: Int
    ) {
        var record = readRecord() ?? Record.empty
        record.completedRows = rowCount
        record.finished = true
        record.finishedAt = Date()
        write(record)
    }

    static func estimatedAudioSeconds(
        rows: Int
    ) -> Double {
        Double(rows) * 1920.0 / 24_000.0
    }

    private func readRecord() -> Record? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func write(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else {
            return
        }

        try? data.write(to: url, options: [.atomic])
    }

    private struct Record: Codable, Sendable {
        var memoryLabel: String
        var targetRows: Int
        var lastStartedRowIndex: Int?
        var completedRows: Int
        var finished: Bool
        var startedAt: Date
        var finishedAt: Date?

        static var empty: Record {
            Record(
                memoryLabel: "unknown",
                targetRows: 0,
                lastStartedRowIndex: nil,
                completedRows: 0,
                finished: false,
                startedAt: Date(),
                finishedAt: nil
            )
        }
    }
}
