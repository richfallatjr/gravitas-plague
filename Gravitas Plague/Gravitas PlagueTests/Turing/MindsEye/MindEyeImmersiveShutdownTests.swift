import XCTest

@testable import Gravitas_Plague

final class MindEyeImmersiveShutdownTests: XCTestCase {
    func testMindEyeShutdownRunsBeforeImmersiveRootsAreTornDown() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        let shutdown = try XCTUnwrap(source.range(of: "func shutdown() async"))
        let tail = String(source[shutdown.lowerBound...])
        let mindEye = try XCTUnwrap(tail.range(of: "mindEyeRuntimeLifecycle.shutdown"))
        let storyRuntime = try XCTUnwrap(tail.range(of: "StoryInteractionPresentationCoordinator.shared.stop()"))
        XCTAssertLessThan(mindEye.lowerBound, storyRuntime.lowerBound)
        XCTAssertTrue(tail.contains("clearMindEye()"))
    }

    func testLifecycleShutdownClearsSubscriptionsRegistriesAndMikeClaims() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeRuntimeLifecycleCoordinator.swift"
        )
        XCTAssertTrue(source.contains("memoryPressureTask?.cancel()"))
        XCTAssertTrue(source.contains("await memoryPressureSource.stop()"))
        XCTAssertTrue(source.contains("clearRegistriesAfterTeardown"))
        XCTAssertTrue(source.contains("sourcePrefix: \"chapter03.mikeBattle.\""))
    }
}
