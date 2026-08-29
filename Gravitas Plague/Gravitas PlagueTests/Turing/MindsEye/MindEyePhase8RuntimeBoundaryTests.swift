import XCTest

@testable import Gravitas_Plague

final class MindEyePhase8RuntimeBoundaryTests: XCTestCase {
    func testAuthoredRuntimeContainsNoAuthoringOrGeneratedAnalysisStack() throws {
        let directory = mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye",
            isDirectory: true
        )
        let authored = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("MindEyeAuthored") }
        let source = try authored.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")
        for forbidden in [
            "montreal_forced_aligner", "silero_vad", "onnxruntime", "kalpy",
            "AVAudioFile", "AVAudioPCMBuffer", "SpeechRecognizer",
            "amplitudeEnvelope", "generatedFrameTrack"
        ] {
            XCTAssertFalse(source.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
    }
}
