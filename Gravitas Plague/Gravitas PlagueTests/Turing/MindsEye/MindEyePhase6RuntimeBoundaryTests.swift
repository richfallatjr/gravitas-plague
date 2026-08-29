import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyePhase6RuntimeBoundaryTests: XCTestCase {
    func testAppTargetDoesNotImportOrInvokeAuthoringStack() throws {
        let root = mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye"
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" || $0.pathExtension == "metal" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .lowercased()

        for forbidden in [
            "import onnxruntime",
            "import torch",
            "import silero",
            "montreal_forced_aligner",
            "process()",
            "executableurl",
            "ffmpeg",
            "ffprobe",
            "audio waveform scan",
            "phoneme inference",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Runtime authoring dependency: \(forbidden)")
        }
    }

    func testSchemaMirrorDoesNotLoadBundleResources() throws {
        let source = try String(
            contentsOf: mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeAuthoredFrameManifest.swift"
            ),
            encoding: .utf8
        ).lowercased()
        XCTAssertFalse(source.contains("bundle."))
        XCTAssertFalse(source.contains("data(contentsof:"))
        XCTAssertFalse(source.contains("audiofile"))
    }
}
