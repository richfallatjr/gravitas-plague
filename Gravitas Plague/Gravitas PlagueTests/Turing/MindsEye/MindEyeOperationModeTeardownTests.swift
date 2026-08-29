import XCTest

@testable import Gravitas_Plague

final class MindEyeOperationModeTeardownTests: XCTestCase {
    func testMindEyeTeardownPrecedesOperationRuntimeRemoval() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        let method = try XCTUnwrap(source.range(of: "private func tearDownOperationModeRuntime("))
        let tail = String(source[method.lowerBound...])
        let mindEye = try XCTUnwrap(tail.range(of: "scope: .operationMode"))
        let ambient = try XCTUnwrap(tail.range(of: "storyAmbientGunfireLifecycle?.deactivateAndWait"))
        XCTAssertLessThan(mindEye.lowerBound, ambient.lowerBound)
        XCTAssertTrue(tail.contains("MindEyeAssetMemoryManager.shared.forceEvictAll"))
        XCTAssertTrue(tail.contains("MindEyeAuthoredFrameTrackStore.shared.forceEvictAll"))
    }
}
