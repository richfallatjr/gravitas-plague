import Foundation
import XCTest

final class MindEyePhase7RuntimeBoundaryTests: XCTestCase {
    func testPhaseSevenDoesNotBundleAuthoringOrAddRuntimePlayback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Gravitas Plague/Turing/MindsEye")
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { ["swift", "metal"].contains($0.pathExtension) }
        let source = try files.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")
        for forbidden in [
            "montreal_forced_aligner",
            "silero_vad",
            "onnxruntime",
            "AVAudioFile",
            "AVAudioPCMBuffer",
            "TextGrid",
            "AuthoredFramePlaybackCursor",
            "GeneratedSpeechFrameTrack",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Phase 7 boundary violation: \(forbidden)")
        }
    }
}
