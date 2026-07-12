import XCTest
@testable import Gravitas_Plague

@MainActor
final class TuringFlowInteractionGateControllerTests:
    XCTestCase {

    func testMicrophoneOpensOnlyAfterCompletionGate()
        async {
        let controller =
            TuringFlowInteractionGateController
                .shared
        await controller.reset(
            reason: "test"
        )

        let identity =
            TuringFlowIdentity(
                scriptPointID: "test.point",
                characterID: "big_mike",
                prerecordingID:
                    "test.point.pr",
                voicePromptID:
                    "test.point.prompt"
            )

        controller.beginFlow(
            identity: identity
        )
        XCTAssertEqual(
            controller.state,
            .busy
        )
        XCTAssertFalse(
            controller.microphoneEnabled
        )

        controller.applyCompletionGate(
            .microphone,
            identity: identity
        )

        XCTAssertEqual(
            controller.state,
            .microphone
        )
        XCTAssertTrue(
            controller.microphoneEnabled
        )
    }

    func testClosedPointDoesNotOpenMicrophone()
        async {
        let controller =
            TuringFlowInteractionGateController
                .shared
        await controller.reset(
            reason: "test"
        )

        let identity =
            TuringFlowIdentity(
                scriptPointID:
                    "test.closed",
                characterID: "rich",
                prerecordingID:
                    "test.closed.pr",
                voicePromptID:
                    "test.closed.prompt"
            )

        controller.beginFlow(
            identity: identity
        )
        controller.applyCompletionGate(
            .closed,
            identity: identity
        )

        XCTAssertEqual(
            controller.state,
            .closed
        )
        XCTAssertFalse(
            controller.microphoneEnabled
        )
    }
}
