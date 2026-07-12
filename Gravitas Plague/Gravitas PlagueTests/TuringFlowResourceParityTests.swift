import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringFlowResourceParityTests:
    XCTestCase {

    func testScriptPoint01Through03UseSchemaTwo()
        throws {
        let store =
            TuringFlowDescriptorStore()
        let point01 =
            try store.require(
                "prologue.scriptPoint01"
            )
        let point02 =
            try store.require(
                "prologue.scriptPoint02"
            )
        let point03 =
            try store.require(
                "prologue.scriptPoint03"
            )

        for point in [
            point01,
            point02,
            point03
        ] {
            XCTAssertEqual(
                point.schemaVersion,
                2
            )
            XCTAssertEqual(
                point.transmission
                    .fillerMode,
                .continuousFromPrerecordingToGenerated
            )
        }

        XCTAssertEqual(
            point01.transmission
                .characterID,
            "big_mike"
        )
        XCTAssertEqual(
            point01.transmission
                .outputRoute,
            .walkieSpatial
        )
        XCTAssertEqual(
            point01.progression
                .interactionGateAfterCompletion,
            .microphone
        )
        XCTAssertEqual(
            point01.progression
                .nextScriptPointID,
            "prologue.scriptPoint02"
        )
        XCTAssertFalse(
            point01.progression
                .automaticAdvance
        )

        XCTAssertEqual(
            point02.transmission
                .characterID,
            "rich"
        )
        XCTAssertEqual(
            point02.transmission
                .outputRoute,
            .walkieOutgoingGlobal
        )
        XCTAssertTrue(
            point02.progression
                .automaticAdvance
        )
        XCTAssertEqual(
            point02.progression
                .nextScriptPointID,
            "prologue.scriptPoint03"
        )
        XCTAssertEqual(
            point02.progression
                .interactionGateAfterCompletion,
            .closed
        )

        XCTAssertEqual(
            point03.transmission
                .characterID,
            "big_mike"
        )
        XCTAssertEqual(
            point03.transmission
                .outputRoute,
            .walkieSpatial
        )
        XCTAssertEqual(
            try XCTUnwrap(
                point03.transmission
                    .fixedLeadInSeconds
            ),
            10,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            point03.progression
                .interactionGateAfterCompletion,
            .microphone
        )
    }

    func testCharacterRegistryLoadsBigMikeAndRich()
        throws {
        let registry =
            try TuringCharacterRuntimeRegistry()

        let mike =
            try registry.require(
                "big_mike"
            )
        let rich =
            try registry.require(
                "rich"
            )

        XCTAssertEqual(
            mike.voiceID,
            "big_mike_base_clone_v1"
        )
        XCTAssertTrue(
            mike.supports(
                .walkieSpatial
            )
        )
        XCTAssertEqual(
            rich.voiceID,
            "rich_base_clone_v1"
        )
        XCTAssertTrue(
            rich.supports(
                .walkieOutgoingGlobal
            )
        )
        XCTAssertTrue(
            rich.supports(
                .roomGlobal
            )
        )
        XCTAssertEqual(
            mike.outputProcessing
                .playbackRate,
            0.85,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            rich.outputProcessing
                .playbackRate,
            0.85,
            accuracy: 0.0001
        )
    }

    func testPromptMarksCurrentPRAlreadySpoken()
        throws {
        let url =
            try TuringResourceLoader
                .resourceURL(
                    resourcePath:
                        "Turing/Prompts/voicePrompt_characterIntent.txt"
                )
        let prompt =
            try String(
                contentsOf: url,
                encoding: .utf8
            )

        XCTAssertTrue(
            prompt.contains(
                "already been spoken or is currently playing"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "Do not restate, paraphrase, summarize, echo, or replay"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "{{authoredPrerecordingJSON}}"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "{{dialogueHistoryJSON}}"
            )
        )
    }

    func testGenericEngineContainsNoProloguePointIDs()
        throws {
        let testFile = URL(
            fileURLWithPath: #filePath
        )
        let productRoot =
            testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        let engineURL =
            productRoot
                .appendingPathComponent(
                    "Gravitas Plague"
                )
                .appendingPathComponent(
                    "Turing/Flow/TuringFlowEngine.swift"
                )
        let source =
            try String(
                contentsOf: engineURL,
                encoding: .utf8
            )

        XCTAssertFalse(
            source.contains(
                "prologue.scriptPoint01"
            )
        )
        XCTAssertFalse(
            source.contains(
                "prologue.scriptPoint02"
            )
        )
        XCTAssertFalse(
            source.contains(
                "prologue.scriptPoint03"
            )
        )
        XCTAssertFalse(
            source.contains(
                "switch character"
            )
        )
    }
}
