import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringVoicePromptContextTests:
    XCTestCase {

    func testCurrentPRIsStructuredAsAlreadySpoken()
        throws {
        let context =
            TuringVoicePromptContext(
                dialogueHistory: [],
                authoredPrerecording:
                    .init(
                        prerecordingID:
                            "point03.pr",
                        speakerID:
                            "big_mike",
                        transcript:
                            "This line already played.",
                        alreadySpoken: true,
                        generatedResponseMustContinueAfterIt:
                            true
                    )
            )

        let json =
            context
                .authoredPrerecordingJSON

        XCTAssertTrue(
            json.contains(
                #""alreadySpoken" : true"#
            )
        )
        XCTAssertTrue(
            json.contains(
                #""generatedResponseMustContinueAfterIt" : true"#
            )
        )
        XCTAssertTrue(
            json.contains(
                "This line already played."
            )
        )
    }

    func testDialogueHistoryKeepsPriorSpeakerSeparateFromCurrentPR()
        async {
        let store =
            TuringDialogueHistoryStore()
        let identity =
            TuringFlowIdentity(
                scriptPointID:
                    "point02",
                characterID: "rich",
                prerecordingID:
                    "point02.pr",
                voicePromptID:
                    "point02.prompt"
            )
        let prerecording =
            TuringFlowTestFixtures
                .prerecording(
                    id: "point02.pr",
                    characterID: "rich",
                    voiceID:
                        "rich_base_clone_v1"
                )

        await store
            .appendCompletedScriptPoint(
                identity: identity,
                prerecording:
                    prerecording,
                generatedSegments: [
                    TuringSpeechSegment(
                        text:
                            "Rich generated continuation.",
                        emotion:
                            "controlled"
                    )
                ],
                conversationKey:
                    "dialogue.big_mike.rich",
                skippedSegmentIndices: []
            )

        let currentPR =
            TuringFlowTestFixtures
                .prerecording(
                    id: "point03.pr",
                    characterID:
                        "big_mike",
                    voiceID:
                        "big_mike_base_clone_v1"
                )
        let context =
            await store
                .makeVoicePromptContext(
                    conversationKey:
                        "dialogue.big_mike.rich",
                    historyLimit: 12,
                    prerecording:
                        currentPR
                )

        XCTAssertEqual(
            context.dialogueHistory
                .map(\.speakerID),
            ["rich", "rich"]
        )
        XCTAssertEqual(
            context.authoredPrerecording
                .speakerID,
            "big_mike"
        )
        XCTAssertFalse(
            context.dialogueHistory
                .contains {
                    $0.text ==
                        currentPR.transcript
                }
        )
    }
}
