import Foundation

actor TuringFoundationPromptArchive {
    static let shared = TuringFoundationPromptArchive()

    private enum ArtifactKind: String, Codable {
        case prompt
        case response
        case error
    }

    private struct ManifestRecord: Codable {
        let timestamp: Date
        let metadata: TuringFoundationRequestMetadata
        let kind: ArtifactKind
        let path: String
        let utf16Count: Int?
        let sha256: String?
        let responseReceived: Bool?
        let message: String?
    }

    private struct ErrorArtifact: Codable {
        let requestID: UUID
        let flowRunID: String?
        let scriptPointID: String?
        let stageID: String?
        let sectionIndex: Int?
        let purpose: String
        let promptUTF16: Int
        let promptSHA256: String
        let responseReceived: Bool
        let error: String
    }

    private let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let caches = (try? FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.rootURL = caches.appendingPathComponent(
                "TuringFoundationLogs",
                isDirectory: true
            )
        }
    }

    func archivePrompt(
        _ prompt: String,
        metadata: TuringFoundationRequestMetadata
    ) throws -> URL {
        let directory = try requestDirectory(metadata)
        let url = directory.appendingPathComponent(
            artifactStem(metadata) + "_prompt.txt"
        )
        try prompt.write(to: url, atomically: true, encoding: .utf8)

        let lastURL = rootURL.appendingPathComponent(
            "last_\(safe(metadata.purpose))_prompt.txt"
        )
        try prompt.write(to: lastURL, atomically: true, encoding: .utf8)
        try appendManifest(
            ManifestRecord(
                timestamp: Date(),
                metadata: metadata,
                kind: .prompt,
                path: url.path,
                utf16Count: prompt.utf16.count,
                sha256: TuringFlowHash.sha256(prompt),
                responseReceived: nil,
                message: nil
            ),
            directory: directory
        )
        return url
    }

    func archiveResponse(
        _ response: String,
        metadata: TuringFoundationRequestMetadata
    ) throws -> URL {
        let directory = try requestDirectory(metadata)
        let url = directory.appendingPathComponent(
            artifactStem(metadata) + "_response.txt"
        )
        try response.write(to: url, atomically: true, encoding: .utf8)
        try appendManifest(
            ManifestRecord(
                timestamp: Date(),
                metadata: metadata,
                kind: .response,
                path: url.path,
                utf16Count: response.utf16.count,
                sha256: TuringFlowHash.sha256(response),
                responseReceived: true,
                message: nil
            ),
            directory: directory
        )
        return url
    }

    func archiveError(
        _ error: Error,
        metadata: TuringFoundationRequestMetadata,
        prompt: String,
        responseReceived: Bool
    ) throws -> URL {
        let directory = try requestDirectory(metadata)
        let url = directory.appendingPathComponent(
            artifactStem(metadata) + "_error.txt"
        )
        let diagnostics = TuringFoundationErrorDiagnostics
            .describe(error)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            ErrorArtifact(
                requestID: metadata.requestID,
                flowRunID: metadata.flowRunID,
                scriptPointID: metadata.scriptPointID,
                stageID: metadata.stageID,
                sectionIndex: metadata.sectionIndex,
                purpose: metadata.purpose,
                promptUTF16: prompt.utf16.count,
                promptSHA256: TuringFlowHash.sha256(prompt),
                responseReceived: responseReceived,
                error: diagnostics
            )
        )
        try data.write(to: url, options: .atomic)
        try appendManifest(
            ManifestRecord(
                timestamp: Date(),
                metadata: metadata,
                kind: .error,
                path: url.path,
                utf16Count: prompt.utf16.count,
                sha256: TuringFlowHash.sha256(prompt),
                responseReceived: responseReceived,
                message: diagnostics
            ),
            directory: directory
        )
        return url
    }

    private func requestDirectory(
        _ metadata: TuringFoundationRequestMetadata
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let directory = rootURL.appendingPathComponent(
            safe(metadata.flowRunID ?? "unscoped"),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func artifactStem(
        _ metadata: TuringFoundationRequestMetadata
    ) -> String {
        "\(metadata.requestID.uuidString)_\(safe(metadata.purpose))"
    }

    private func safe(_ value: String) -> String {
        let mapped = value.map { character in
            character.isLetter || character.isNumber || character == "_" ||
                character == "-" ? character : "_"
        }
        return String(mapped)
    }

    private func appendManifest(
        _ record: ManifestRecord,
        directory: URL
    ) throws {
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)
        let url = directory.appendingPathComponent("manifest.ndjson")
        if FileManager.default.fileExists(atPath: url.path) == false {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
