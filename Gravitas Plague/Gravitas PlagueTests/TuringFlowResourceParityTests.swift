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
            .microphone
        )
        XCTAssertEqual(
            point02.progression
                .effectiveInteractionGateAfterCompletion,
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

    func testScriptPoint04AutomaticallyBridgesIntoScriptPoint05()
        throws {
        let store = TuringFlowDescriptorStore()
        let point04 = try store.require(
            "prologue.scriptPoint04"
        )
        let point05 = try store.require(
            "prologue.scriptPoint05"
        )

        XCTAssertTrue(point04.progression.automaticAdvance)
        XCTAssertEqual(
            point04.progression.nextScriptPointID,
            "prologue.scriptPoint05"
        )
        XCTAssertEqual(
            point04.progression.effectiveInteractionGateAfterCompletion,
            .closed
        )
        XCTAssertEqual(
            point05.trigger.kind,
            .priorScriptPointCompleted
        )
        XCTAssertEqual(
            point05.transmission.computeStart,
            .beforePrerecording
        )
        XCTAssertEqual(
            try XCTUnwrap(point05.transmission.fixedLeadInSeconds),
            10,
            accuracy: 0.0001
        )
    }

    func testScriptPoint05UsesDebugHeadlineThenStandardPRPromptVoice()
        throws {
        let point05 = try TuringFlowDescriptorStore().require(
            "prologue.scriptPoint05"
        )
        let pipeline = try XCTUnwrap(
            point05.transmission.generationPipeline
        )

        XCTAssertEqual(pipeline.stages.count, 2)
        XCTAssertEqual(pipeline.stages[0].kind, .voiceScriptLongform)
        XCTAssertEqual(pipeline.stages[1].kind, .voicePrompt)
        XCTAssertEqual(
            pipeline.stages[1].voicePromptID,
            "prologue.bigMike.scriptPoint05.promptVoice.001"
        )
        XCTAssertEqual(pipeline.stages[1].stageID, "promptVoice")
        XCTAssertEqual(
            pipeline.stages[1].contextSource.kind,
            .prerecordingTranscript
        )
        XCTAssertNil(pipeline.stages[1].contextSource.stageID)

        let sourcePath = try XCTUnwrap(
            pipeline.stages[0].sourceResourcePath
        )
        let sourceURL = try TuringResourceLoader.resourceURL(
            resourcePath: sourcePath
        )
        let source = try String(
            contentsOf: sourceURL,
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Rich, listen to this stuff."))
        XCTAssertTrue(source.contains("THE GRAVITAS PLAGUE SPREADS"))
        XCTAssertTrue(source.contains("They look awake, but unreachable."))
        XCTAssertTrue(source.contains("If speech fails, do not negotiate."))
        XCTAssertFalse(source.contains("Federal Public Health Service advisory"))
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

    func testVoicePromptUsesOnlyApprovedContextInputs()
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
                "{{characterProfile}}"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "{{promptContext}}"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "{{prerecordingTranscript}}"
            )
        )
        XCTAssertFalse(
            prompt.contains(
                "{{dialogueHistoryJSON}}"
            )
        )
        XCTAssertFalse(
            prompt.contains(
                "{{authoredPrerecordingJSON}}"
            )
        )
        XCTAssertFalse(
            prompt.contains(
                "{{voicePromptSeedIntent}}"
            )
        )
    }

    func testConversationPromptUsesOnlyApprovedContextInputs()
        throws {
        let url =
            try TuringResourceLoader
                .resourceURL(
                    resourcePath:
                        "Turing/Prompts/conversationPrompt_playerTurn_noBible.txt"
                )
        let prompt =
            try String(
                contentsOf: url,
                encoding: .utf8
            )

        for placeholder in [
            "{{userInput}}",
            "{{characterProfile}}",
            "{{promptContext}}",
            "{{prerecordingTranscript}}"
        ] {
            XCTAssertTrue(prompt.contains(placeholder))
        }
        XCTAssertFalse(prompt.contains("{{lastVoicePromptSeed}}"))
        XCTAssertFalse(prompt.contains("{{dialogueHistoryJSON}}"))
        XCTAssertFalse(prompt.contains("{{episodeStateForWordsOnly}}"))
        XCTAssertTrue(prompt.contains("This is what you last said:"))
        XCTAssertFalse(prompt.contains("Current prerecording transcript:"))
    }

    func testConversationUsesExactCurrentPromptVoiceSeed()
        async throws {
        let descriptorStore = TuringVoicePromptTriggerStore()
        let point01 = try descriptorStore.descriptor(
            id: "prologue.bigMike.scriptPoint01.followUp.001"
        )
        let point03 = try descriptorStore.descriptor(
            id: "prologue.bigMike.scriptPoint03.followUp.001"
        )
        let point01Seed = TuringPromptVoiceSeedBuilder.standard(point01)
        let point03Seed = TuringPromptVoiceSeedBuilder.standard(point03)

        XCTAssertTrue(point01Seed.promptContext.contains(point01.intent))
        XCTAssertTrue(point01Seed.promptContext.contains(point01.emotion))
        XCTAssertTrue(point03Seed.promptContext.contains(point03.intent))
        XCTAssertTrue(point03Seed.promptContext.contains(point03.emotion))
        XCTAssertNotEqual(point01Seed.promptContext, point03Seed.promptContext)

        let store = TuringConversationSeedStore()
        await store.updatePromptVoiceSeed(
            point01Seed,
            for: TuringDialogueThreadIdentity.bigMikeRich
        )
        await store.updatePromptVoiceSeed(
            point03Seed,
            for: TuringDialogueThreadIdentity.bigMikeRich
        )
        let active = await store.promptVoiceSeed(
            for: TuringDialogueThreadIdentity.bigMikeRich
        )

        XCTAssertEqual(active, point03Seed)
    }

    func testConversationRunnerContainsNoHistoryOrFabricatedContext()
        throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let runnerURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Gravitas Plague")
            .appendingPathComponent(
                "Turing/Flow/TuringFlowConversationRunner.swift"
            )
        let source = try String(contentsOf: runnerURL, encoding: .utf8)

        XCTAssertTrue(source.contains("promptVoiceSeed.promptContext"))
        XCTAssertFalse(source.contains("episodeStateForWordsOnly"))
        XCTAssertFalse(source.contains("appendConversation"))
        XCTAssertFalse(source.contains("TuringDialogueHistoryStore"))
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
