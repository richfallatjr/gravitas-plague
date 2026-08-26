import Foundation

public struct TuringQwenNativeTrace: Sendable {
    private let prefix: String

    public static func stdout(prefix: String) -> TuringQwenNativeTrace {
        TuringQwenNativeTrace(prefix: prefix)
    }

    public init(prefix: String) {
        self.prefix = prefix
    }

    public func stageStarted(_ stage: TuringQwenNativeStage) {
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "stage.started.\(stage.rawValue)",
            details: ["tracePrefix": prefix]
        )
        print("\(prefix) stage started \(stage.rawValue)")
    }

    public func stageCompleted(_ stage: TuringQwenNativeStage) {
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "stage.completed.\(stage.rawValue)",
            details: ["tracePrefix": prefix]
        )
        print("\(prefix) stage completed \(stage.rawValue)")
    }

    public func tensor(
        _ name: String,
        shape: [Int],
        dtype: String,
        ndim: Int
    ) {
        print("""
        [TuringQwenNativeTensor] \(name)
          shape: \(shape)
          dtype: \(dtype)
          ndim: \(ndim)
        """)
    }
}

public enum TuringQwenNativeStage: String, Codable, Sendable {
    case assetPreflight
    case tokenizerLoad
    case tensorIndexLoad
    case weightMapValidate
    case promptBuild
    case promptEmbeddingsEval
    case talkerPromptInputEval
    case talkerLayer0Eval
    case talkerAllLayersEval
    case talkerCodecHeadEval
    case talkerForwardFirstEval
    case sampleFirstToken
    case codePredictorFirstEval
    case codePredictorCodebookEval
    case speechDecoderFirstEval
    case fullGenerate
    case audioMaterialized
    case playbackStarted
    case playbackFinished
}

public struct TuringQwenNativeStageBreadcrumbs: Sendable {
    private let url: URL

    public init() throws {
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

        self.url = root.appendingPathComponent("canary-last-stage.json")
    }

    public func logPreviousRunIfNeeded(prefix: String) {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.lastStartedStage != record.lastCompletedStage else {
            return
        }

        print("""
        \(prefix) previous run likely process-asserted
          lastStartedStage: \(record.lastStartedStage?.rawValue ?? "nil")
          lastCompletedStage: \(record.lastCompletedStage?.rawValue ?? "nil")
        """)
    }

    public func started(_ stage: TuringQwenNativeStage) {
        var record = readRecord()
        record.lastStartedStage = stage
        write(record)
    }

    public func completed(_ stage: TuringQwenNativeStage) {
        var record = readRecord()
        record.lastCompletedStage = stage
        write(record)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private func readRecord() -> Record {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return Record(lastStartedStage: nil, lastCompletedStage: nil)
        }

        return record
    }

    private func write(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else {
            return
        }

        try? data.write(to: url, options: [.atomic])
    }

    private struct Record: Codable {
        var lastStartedStage: TuringQwenNativeStage?
        var lastCompletedStage: TuringQwenNativeStage?
    }
}
