import XCTest

@testable import Gravitas_Plague

final class MindEyeDynamicOutputSurfaceMotionTests: XCTestCase {
    func testSurfaceOwnsMergeStateAndReusableOutputObjects() throws {
        let body = try source()
        XCTAssertTrue(body.contains("let lowLevelTexture: LowLevelTexture"))
        XCTAssertTrue(body.contains("let textureResource: TextureResource"))
        XCTAssertTrue(body.contains("let outputPlane: ModelEntity"))
        XCTAssertTrue(body.contains("currentMouthSelection"))
        XCTAssertTrue(body.contains("currentMaskMode"))
        XCTAssertTrue(body.contains("nextCompositeSequence"))
        XCTAssertTrue(body.contains("backgroundTransform: sample.backgroundTransform"))
        XCTAssertTrue(body.contains("characterTransform: sample.characterTransform"))
        XCTAssertTrue(body.contains("eyeSelection: sample.eyeSelection"))
        XCTAssertTrue(body.contains("mouthSelection: currentMouthSelection"))
        XCTAssertTrue(body.contains("maskMode: currentMaskMode"))
    }

    func testKeepAliveLifecycleOwnsOneComponentAndWeakToken() throws {
        let body = try source()
        XCTAssertTrue(body.contains("MindEyeMotionFrameRegistry.shared.register(self)"))
        XCTAssertTrue(body.contains("contentRoot.components[MindEyeMotionComponent.self]"))
        XCTAssertTrue(body.contains("contentRoot.components.remove(MindEyeMotionComponent.self)"))
        XCTAssertTrue(body.contains("MindEyeMotionFrameRegistry.shared.unregister"))
        XCTAssertTrue(body.contains("stopKeepAlive(reason: reason)"))
    }

    func testPauseUpdatesBothSimulationAndGPUFrameMailbox() throws {
        let body = try source()
        XCTAssertTrue(body.contains("frameUpdatesPaused = paused"))
        XCTAssertTrue(body.contains("component.isPaused = paused"))
        XCTAssertTrue(body.contains("if !paused, pendingFrame != nil"))
    }

    private func source() throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeDynamicOutputSurface.swift"
            ),
            encoding: .utf8
        )
    }
}
