#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import CryptoKit
import Foundation

actor MindEyeProjectionExportStore {
    let captureID: String
    let root: URL
    let staging: URL
    private let fileManager = FileManager.default

    init(captureID: String) throws {
        self.captureID = captureID
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let parent = appSupport.appendingPathComponent("MindEyeProjectionAuthoring", isDirectory: true)
        root = parent.appendingPathComponent(captureID, isDirectory: true)
        staging = parent.appendingPathComponent("\(captureID).inprogress.\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    func url(_ filename: String) -> URL { staging.appendingPathComponent(filename) }

    func write<T: Encodable>(_ value: T, filename: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: url(filename), options: .atomic)
    }

    func write(_ data: Data, filename: String) throws {
        try data.write(to: url(filename), options: .atomic)
    }

    func publish(marker: MindEyeProjectionCompletionMarker) throws {
        try write(marker, filename: "\(captureID)_complete.json")
        if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
        try fileManager.moveItem(at: staging, to: root)
    }

    func publishFailure(_ error: Error) throws {
        let marker = MindEyeProjectionCompletionMarker(
            schemaVersion: 1,
            captureID: captureID,
            status: "failed",
            manifest: nil,
            cameraSHA256: nil,
            outputSetSHA256: nil,
            failureCode: String(describing: type(of: error)),
            message: String(error.localizedDescription.prefix(800))
        )
        try publish(marker: marker)
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sha256(file url: URL) throws -> String {
        sha256(try Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}
#endif
