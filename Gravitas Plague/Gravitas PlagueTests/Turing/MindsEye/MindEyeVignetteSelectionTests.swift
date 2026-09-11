import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeVignetteSelectionTests: XCTestCase {
    func testChapter03BigMikeUsesDamagedVignette() {
        let selection = MindEyeVignetteSelection(
            characterID: .bigMike,
            run: run(scriptPointID: "chapter03.walkie.bigMike.fading.003")
        )

        XCTAssertEqual(
            selection.preferredVignetteID,
            "big_mike_damaged"
        )
    }

    func testEarlierBigMikeAndOtherChapter03CharactersKeepDefaults() {
        let earlierMike = MindEyeVignetteSelection(
            characterID: .bigMike,
            run: run(scriptPointID: "chapter02.walkie.bigMike.script03")
        )
        let chapter03Rich = MindEyeVignetteSelection(
            characterID: .rich,
            run: run(
                scriptPointID: "chapter03.walkie.rich.connectsMen.002",
                characterID: .rich
            )
        )

        XCTAssertNil(earlierMike.preferredVignetteID)
        XCTAssertNil(chapter03Rich.preferredVignetteID)
        XCTAssertNotEqual(
            earlierMike,
            MindEyeVignetteSelection(
                characterID: .bigMike,
                run: run(scriptPointID: "chapter03.walkie.bigMike.fading.003")
            )
        )
    }

    func testChapter03GeneratedReplyInheritsDamagedVignetteFromAuthoredParent() {
        let parentFlowID = UUID()
        let childFlowID = UUID()
        let continuity = TuringSpokenPresentationContinuity(
            continuityID: UUID(),
            parent: .init(
                playbackRunID:
                    "chapter03.walkie.bigMike.fading.003.\(parentFlowID.uuidString)",
                flowInstanceID: parentFlowID,
                mediaIdentity:
                    "authored.primary.chapter03.walkie.bigMike.fading.003"
            ),
            childPlaybackRunID: childFlowID.uuidString,
            childFlowInstanceID: childFlowID,
            speakerCharacterID: .bigMike,
            interactionSurface: .walkie
        )
        let generatedRun = run(
            scriptPointID: "conversation.\(childFlowID.uuidString)",
            continuity: continuity
        )

        XCTAssertEqual(
            MindEyeVignetteSelection(
                characterID: .bigMike,
                run: generatedRun
            ).preferredVignetteID,
            "big_mike_damaged"
        )
        XCTAssertEqual(
            MindEyeVignetteSelection(continuity: continuity)
                .preferredVignetteID,
            "big_mike_damaged"
        )
    }

    private func run(
        scriptPointID: String,
        characterID: TuringConversationCharacterID = .bigMike,
        continuity: TuringSpokenPresentationContinuity? = nil
    ) -> TuringSpokenPresentationRunIdentity {
        TuringSpokenPresentationRunIdentity(
            flowIdentity: TuringFlowIdentity(
                scriptPointID: scriptPointID,
                characterID: characterID.rawValue,
                prerecordingID: "test",
                voicePromptID: "test",
                interactionSurface: .walkie,
                spokenPresentationContinuity: continuity
            )
        )
    }
}
