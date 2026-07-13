import XCTest
@testable import Gravitas_Plague

@MainActor
final class TuringStoryWalkiePresentationTests: XCTestCase {
    func testPresentationIsDerivedFromInteractionGate() {
        XCTAssertEqual(
            TuringStoryWalkiePresentation(gate: .closed),
            .hidden
        )
        XCTAssertEqual(
            TuringStoryWalkiePresentation(gate: .busy),
            .hidden
        )
        XCTAssertEqual(
            TuringStoryWalkiePresentation(gate: .play),
            .play
        )
        XCTAssertEqual(
            TuringStoryWalkiePresentation(gate: .microphone),
            .microphone
        )
    }

    func testAutomaticAdvanceSuppressesAuthoredMicrophoneGate() {
        let progression = TuringFlowDescriptor.Progression(
            nextScriptPointID: "prologue.scriptPoint03",
            automaticAdvance: true,
            interactionGateAfterCompletion: .microphone
        )

        XCTAssertEqual(
            progression.effectiveInteractionGateAfterCompletion,
            .closed
        )
    }

    func testTerminalPointPreservesAuthoredMicrophoneGate() {
        let progression = TuringFlowDescriptor.Progression(
            nextScriptPointID: nil,
            automaticAdvance: false,
            interactionGateAfterCompletion: .microphone
        )

        XCTAssertEqual(
            progression.effectiveInteractionGateAfterCompletion,
            .microphone
        )
    }
}
