import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredMouthSurfaceIntegrationTests: XCTestCase {
    func testMotionAndMouthUseOneMergedCompositorState() throws {
        let source = try String(
            contentsOf: mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeDynamicOutputSurface.swift"
            ),
            encoding: .utf8
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "mouthSelection: currentMouthSelection").count - 1,
            1
        )
        XCTAssertTrue(source.contains("backgroundTransform: latestMotionSample.backgroundTransform"))
        XCTAssertTrue(source.contains("eyeSelection: latestMotionSample.eyeSelection"))
        XCTAssertTrue(source.contains("maskMode: currentMaskMode"))
        XCTAssertTrue(source.contains("package.mouths.teeth.count"))
        XCTAssertTrue(source.contains("stopAuthoredMouthPlayback(reason: reason, resetToRest: false)"))
    }
}
