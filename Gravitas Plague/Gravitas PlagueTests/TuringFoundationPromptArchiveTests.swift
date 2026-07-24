import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringFoundationPromptArchiveTests: XCTestCase {
    func testGuardrailFailureArchivesPromptAndErrorWithoutResponse()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TuringFoundationPromptArchive(rootURL: root)
        let metadata = TuringFoundationRequestMetadata(
            requestID: UUID(),
            flowRunID: "flow-run",
            scriptPointID: "prologue.scriptPoint05",
            stageID: "promptVoice",
            sectionIndex: nil,
            purpose: "voicePrompt"
        )
        let exactPrompt = "Exact sanitized prompt."

        let promptURL = try await archive.archivePrompt(
            exactPrompt,
            metadata: metadata
        )
        let errorURL = try await archive.archiveError(
            NSError(
                domain: "FoundationGuardrail",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Guardrail rejected"]
            ),
            metadata: metadata,
            prompt: exactPrompt,
            responseReceived: false
        )

        XCTAssertEqual(
            try String(contentsOf: promptURL, encoding: .utf8),
            exactPrompt
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: errorURL.path))
        let requestDirectory = promptURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            atPath: requestDirectory.path
        )
        XCTAssertFalse(files.contains { $0.hasSuffix("_response.txt") })
        XCTAssertTrue(files.contains("manifest.ndjson"))
    }

    func testResponseArchiveUsesSameRequestIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TuringFoundationPromptArchive(rootURL: root)
        let metadata = TuringFoundationRequestMetadata(
            requestID: UUID(),
            flowRunID: "flow-run",
            scriptPointID: "prologue.scriptPoint05",
            stageID: "headlineReading",
            sectionIndex: 0,
            purpose: "voiceScriptSectionSegmentation"
        )

        let promptURL = try await archive.archivePrompt(
            "prompt",
            metadata: metadata
        )
        let responseURL = try await archive.archiveResponse(
            "response",
            metadata: metadata
        )

        XCTAssertEqual(
            promptURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_prompt", with: ""),
            responseURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_response", with: "")
        )
    }
}
