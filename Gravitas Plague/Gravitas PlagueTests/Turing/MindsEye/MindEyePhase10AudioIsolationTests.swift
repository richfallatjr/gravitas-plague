import XCTest

@testable import Gravitas_Plague

final class MindEyePhase10AudioIsolationTests: XCTestCase {
    func testPhase10LifecycleFilesDoNotControlAudioEndpoints() throws {
        let paths = [
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeApplicationLifecycle.swift",
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeMemoryPressure.swift",
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeRuntimeLifecycleCoordinator.swift"
        ]
        let source = try paths.map(MindEyePhase10Source.read).joined(separator: "\n")
        for forbidden in [
            "TuringAudioPlaybackEndpoint",
            "TuringAudioPlaybackController",
            "pauseAudio",
            "stopAudio",
            "playAudio("
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}
