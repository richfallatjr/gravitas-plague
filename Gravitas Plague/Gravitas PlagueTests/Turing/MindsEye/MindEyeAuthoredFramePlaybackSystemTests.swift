import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFramePlaybackSystemTests: XCTestCase {
    func testRenderingSystemHasNoPerFrameTaskOrDeltaTimeClock() throws {
        let source = try sourceText("MindEyeAuthoredFramePlaybackSystem.swift")
        XCTAssertTrue(source.contains("updatingSystemWhen: .rendering"))
        XCTAssertTrue(source.contains("let now = ContinuousClock.now"))
        XCTAssertFalse(source.contains("Task {"))
        XCTAssertFalse(source.contains("deltaTime"))
        XCTAssertFalse(source.contains("Data(contentsOf:"))
        XCTAssertFalse(source.contains("TextureResource"))
    }

    private func sourceText(_ name: String) throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/MindsEye/\(name)"
            ),
            encoding: .utf8
        )
    }
}
