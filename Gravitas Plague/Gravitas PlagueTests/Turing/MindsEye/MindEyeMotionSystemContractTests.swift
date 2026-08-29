import XCTest

@testable import Gravitas_Plague

final class MindEyeMotionSystemContractTests: XCTestCase {
    func testRealityKitRenderingSystemContract() throws {
        let component = try source("MindEyeMotionComponent.swift")
        let system = try source("MindEyeMotionSystem.swift")
        let registration = try source("MindEyeRuntimeRegistration.swift")
        XCTAssertTrue(component.contains("TransientComponent"))
        XCTAssertTrue(system.contains(".has(MindEyeMotionComponent.self)"))
        XCTAssertTrue(system.contains("updatingSystemWhen: .rendering"))
        XCTAssertTrue(system.contains("context.deltaTime"))
        XCTAssertTrue(system.contains("MindEyeMotionFrameRegistry.shared.publish"))
        XCTAssertTrue(system.contains("entity.components[MindEyeMotionComponent.self] = component"))
        XCTAssertTrue(registration.contains("MindEyeMotionComponent.registerComponent()"))
        XCTAssertTrue(registration.contains("MindEyeMotionSystem.registerSystem()"))
    }

    func testMotionUpdatePathContainsNoHeavyOrAlternateUpdateAPIs() throws {
        let names = [
            "MindEyeMotionModel.swift",
            "MindEyeMotionSystem.swift",
            "MindEyeBlinkScheduler.swift",
            "MindEyeSelfieProjection.swift"
        ]
        let body = try names.map(source).joined(separator: "\n")
        for forbidden in [
            "Timer.", "scheduledTimer", "SceneEvents.Update", "Task.detached",
            "Data(contentsOf:", "CGContext", "CGImage", "UIImage", "CVPixelBuffer",
            "MTKTextureLoader", "TextureResource.load", "SystemRandomNumberGenerator",
            "Float.random", "Double.random", "Int.random", "hashValue"
        ] {
            XCTAssertFalse(body.contains(forbidden), "Forbidden update API: \(forbidden)")
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
