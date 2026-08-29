import XCTest

@testable import Gravitas_Plague

final class MindEyeReleaseQualificationHooksTests: XCTestCase {
    func testActiveHooksAreQualificationGatedAndAudioHookIsFireAndForget() throws {
        let hooks = try MindEyePhase11TestSource.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeReleaseQualificationHooks.swift"
        )
        XCTAssertTrue(hooks.contains("#if GR_MIND_EYE_QUALIFICATION"))
        XCTAssertTrue(hooks.contains("TuringSpokenPresentationHub.shared.events()"))
        XCTAssertTrue(hooks.contains(".authoredAudioStarted"))
        XCTAssertTrue(hooks.contains(".generatedAudioStarted"))
        XCTAssertTrue(hooks.contains("fireAndForget("))
        let presentation = try MindEyePhase11TestSource.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift"
        )
        XCTAssertTrue(presentation.contains(".afterVisualAttach"))
        XCTAssertTrue(presentation.contains("fireAndForget("))
    }
}
