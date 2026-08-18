import XCTest
@testable import Gravitas_Plague

final class TuringLiveConversationCatalogTests: XCTestCase {
    func testCatalogValidatesAgainstProductionResources() throws {
        try TuringLiveConversationCatalogValidator().validate()
    }

    func testCatalogKeysAreUnique() throws {
        let entries = try TuringLiveConversationCatalogStore().entries
        let keys = entries.map {
            "\($0.scriptPointID)|\($0.authoredPrerecordingID)"
        }

        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testScriptPoint05UsesSecondPRAndPromptVoiceStage() throws {
        let entry = try XCTUnwrap(
            TuringLiveConversationCatalogStore().entry(
                scriptPointID: "prologue.scriptPoint05",
                authoredPrerecordingID:
                    "prologue.walkie.bigMike.scriptPoint05.002"
            )
        )

        XCTAssertEqual(entry.voicePromptSource.kind, .generationPipelineStage)
        XCTAssertEqual(entry.voicePromptSource.stageID, "promptVoice")
        XCTAssertNil(entry.voicePromptSource.voicePromptID)
        XCTAssertEqual(entry.retention, .untilExplicitInvalidation)
        XCTAssertEqual(entry.interactionSurface, .walkie)
    }

    func testScriptPoint05FirstPRIsNotConversationSeed() throws {
        XCTAssertNil(
            try TuringLiveConversationCatalogStore().entry(
                scriptPointID: "prologue.scriptPoint05",
                authoredPrerecordingID:
                    "prologue.walkie.bigMike.scriptPoint05.001"
            )
        )
    }
}
