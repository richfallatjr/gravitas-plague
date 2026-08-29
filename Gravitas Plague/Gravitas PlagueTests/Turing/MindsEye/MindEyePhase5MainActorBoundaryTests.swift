import XCTest

@testable import Gravitas_Plague

final class MindEyePhase5MainActorBoundaryTests: XCTestCase {
    func testRenderingSystemContainsOnlyBoundedStateMathAndPublish() throws {
        let system = try source("MindEyeMotionSystem.swift")
        XCTAssertTrue(system.contains("MindEyeMotionModel.advance"))
        XCTAssertTrue(system.contains("MindEyeMotionFrameRegistry.shared.publish"))
        for forbidden in [
            "Task {", "Task.detached", "Data(contentsOf:", "FileManager",
            "CGContext", "CGImage", "UIImage", "CVPixelBuffer",
            "MTKTextureLoader", "TextureResource.load", "makeCommandBuffer"
        ] {
            XCTAssertFalse(system.contains(forbidden), "Forbidden per-frame work: \(forbidden)")
        }
    }

    func testPixelWorkRemainsInMetalAndMotionModelHasNoGPUOwnership() throws {
        let metal = try source("MindEyeComposite.metal")
        let motion = try source("MindEyeMotionModel.swift")
        XCTAssertTrue(metal.contains("kernel void mindEyeComposite"))
        for forbidden in ["MTLTexture", "LowLevelTexture", "TextureResource", "ModelEntity"] {
            XCTAssertFalse(motion.contains(forbidden))
        }
    }

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot()
                .appendingPathComponent("Gravitas Plague/Gravitas Plague/Turing/MindsEye")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
