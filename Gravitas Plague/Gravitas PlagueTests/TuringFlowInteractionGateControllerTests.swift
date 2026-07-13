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

    func testPlayClaimIsSynchronousAndAcceptsOnlyOnce()
        async {
        let controller =
            TuringFlowInteractionGateController.shared
        await controller.reset(reason: "test")

        controller.armPlay(reason: "testReady")

        XCTAssertTrue(
            controller.claimPlay(reason: "firstTap")
        )
        XCTAssertEqual(controller.state, .busy)
        XCTAssertFalse(
            controller.claimPlay(reason: "secondTap")
        )
    }

    func testFailedUnownedPlayClaimCanRestorePlay()
        async {
        let controller =
            TuringFlowInteractionGateController.shared
        await controller.reset(reason: "test")

        controller.armPlay(reason: "testReady")
        XCTAssertTrue(
            controller.claimPlay(reason: "testTap")
        )
        controller.restorePlayAfterFailedClaim(
            reason: "testFailure"
        )

        XCTAssertEqual(controller.state, .play)
    }

    func testProgressionFailureRestoresMicrophone()
        async {
        let controller =
            TuringFlowInteractionGateController.shared
        await controller.reset(reason: "test")

        let identity =
            TuringFlowIdentity(
                scriptPointID:
                    "prologue.scriptPoint03",
                characterID: "big_mike",
                prerecordingID:
                    "prologue.scriptPoint03.pr",
                voicePromptID:
                    "prologue.scriptPoint03.prompt"
            )

        controller.beginFlow(identity: identity)
        controller.failFlow(
            identity: identity,
            reason: "partialGeneratedFailure"
        )
        XCTAssertEqual(controller.state, .closed)

        controller.restoreMicrophoneAfterProgressionFailure(
            conversationRunID: UUID(),
            reason: "scriptPoint03 failed"
        )

        XCTAssertEqual(controller.state, .microphone)
        XCTAssertTrue(controller.microphoneEnabled)
    }

    func testTerminalMicrophoneInvariantRepairsClosedGate()
        async {
        let controller =
            TuringFlowInteractionGateController.shared
        await controller.reset(reason: "test")

        controller.ensureMicrophoneAvailable(
            reason: "terminalPointCompleted.test"
        )

        XCTAssertEqual(controller.state, .microphone)
        XCTAssertTrue(controller.microphoneEnabled)
    }
}
