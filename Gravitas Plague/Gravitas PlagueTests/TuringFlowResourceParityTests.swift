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
            pipeline.stages[0].authoredPrerecordingAfterStageID,
            "prologue.walkie.bigMike.scriptPoint05.002"
        )
        XCTAssertNil(
            pipeline.stages[1].authoredPrerecordingAfterStageID
        )
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

        let promptDescriptor = try TuringVoicePromptTriggerStore()
            .descriptor(
                id: "prologue.bigMike.scriptPoint05.promptVoice.001"
            )
        let promptContext =
            TuringPromptVoiceStoryContextBuilder.standard(
            promptDescriptor
        )
        XCTAssertEqual(
            promptContext.storyContext,
            """
            Story Intent:
            I'm trying to support Rich but he may have messed up. I'll just let him know he did what he had to do. We both need to keep our eyes sharp and help each other out to stay safe. I am glad Rich is alright. Rich needs to get that ham radio functional so we can communicate better with the outside world which is completely the grid now.
            """
        )
        XCTAssertFalse(
            promptContext.storyContext.contains("Emotional tone:")
        )
        XCTAssertFalse(
            promptContext.storyContext.contains("promptVoice")
        )
        XCTAssertEqual(
            promptDescriptor.listenerProfileID,
            "rich"
        )
        let templateURL = try TuringResourceLoader.resourceURL(
            resourcePath:
                "Turing/Prompts/voicePrompt_characterIntent.txt"
        )
        let template = try String(
            contentsOf: templateURL,
            encoding: .utf8
        )
        XCTAssertTrue(
            template.hasPrefix(
                "You are {{characterDisplayName}}. You are talking to {{listenerDisplayName}} over walkie talkie."
            )
        )
        XCTAssertTrue(template.contains("{{characterDisplayName}}"))
        XCTAssertTrue(template.contains("{{listenerDisplayName}}"))
        XCTAssertTrue(template.contains("{{storyIntent}}"))
        XCTAssertTrue(template.contains("{{characterBackstory}}"))
        XCTAssertTrue(template.contains("{{prerecordingTranscript}}"))
        XCTAssertFalse(template.contains("{{characterProfile}}"))
        XCTAssertFalse(template.contains("{{promptContext}}"))
        XCTAssertFalse(template.contains("conversationSeed"))

        let profile = try TuringCharacterProfileStore().profile(
            id: promptDescriptor.characterProfileID
        )
        let listenerProfile = try TuringCharacterProfileStore().profile(
            id: promptDescriptor.listenerProfileID
        )
        let prerecording = try TuringPrerecordingStore().descriptor(
            id: "prologue.walkie.bigMike.scriptPoint05.001"
        )
        let authoredBridge = try TuringPrerecordingStore().descriptor(
            id: "prologue.walkie.bigMike.scriptPoint05.002"
        )
        XCTAssertEqual(
            authoredBridge.audioFile,
            "pr-2-script05-big-mike.mp3"
        )
        XCTAssertEqual(authoredBridge.transcriptMode, .manual)
        XCTAssertEqual(
            authoredBridge.transcript,
            "Rich, you still with me? I heard enough to know something happened, but keep the details off this channel. Just tell me you’re standing and the house is secure. I’ve been checking the regular bands, and they’re getting worse—dead air, crossed signals, people talking over each other. That old ham setup of yours might be the only thing with enough reach. See if it powers up. Check the antenna. Don’t transmit yet. Just let me know if it’s alive."
        )
        XCTAssertNoThrow(
            try TuringPrerecordingStore().audioURL(for: authoredBridge)
        )
        let rendered = template
            .replacingOccurrences(
                of: "{{characterDisplayName}}",
                with: profile.displayName
            )
            .replacingOccurrences(
                of: "{{listenerDisplayName}}",
                with: listenerProfile.displayName
            )
            .replacingOccurrences(
                of: "{{characterBackstory}}",
                with: profile.writeup
            )
            .replacingOccurrences(
                of: "{{storyIntent}}",
                with: promptDescriptor.intent
            )
            .replacingOccurrences(
                of: "{{prerecordingTranscript}}",
                with: prerecording.transcript
            )
        XCTAssertTrue(
            rendered.hasPrefix(
                "You are Big Mike. You are talking to Rich over walkie talkie."
            )
        )
        XCTAssertTrue(rendered.contains(profile.writeup))
        XCTAssertTrue(rendered.contains(promptDescriptor.intent))
        XCTAssertTrue(rendered.contains(prerecording.transcript))
        XCTAssertFalse(rendered.contains("Big Mike (big_mike)"))
        XCTAssertFalse(rendered.contains("Voice: big_mike_base_clone_v1"))
        XCTAssertFalse(rendered.contains("{{"))
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
                "You are {{characterDisplayName}}. You are talking to {{listenerDisplayName}} over walkie talkie."
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "This is your backstory:"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "{{characterBackstory}}"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "{{storyIntent}}"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "{{prerecordingTranscript}}"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "This is what you just said prior to what you are going to say next:"
            )
        )
        XCTAssertTrue(
            prompt.contains(
                "Paraphrase the Story Intent in {{characterDisplayName}}'s voice."
            )
        )
        XCTAssertTrue(
            prompt.hasPrefix(
                "You are {{characterDisplayName}}."
            )
        )
        XCTAssertFalse(prompt.contains("{{characterProfile}}"))
        XCTAssertFalse(prompt.contains("{{promptContext}}"))
        XCTAssertFalse(
            prompt.contains(
                "Do not restate, paraphrase, summarize, echo, or replay"
            )
        )
        XCTAssertFalse(
            prompt.contains(
                "You are writing"
            )
        )
        XCTAssertFalse(
            prompt.contains(
                "conversationSeed"
            )
        )
        XCTAssertFalse(
            prompt.contains(
                "Current prerecording transcript:"
            )
        )
        XCTAssertFalse(
            prompt.contains(
                "Prompt context:"
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

    func testScriptPoint05ConversationPromptHasDedicatedContract()
        throws {
        let url =
            try TuringResourceLoader.resourceURL(
                resourcePath:
                    "Turing/Prompts/conversationPrompt_scriptPoint05.txt"
            )
        let prompt =
            try String(
                contentsOf: url,
                encoding: .utf8
            )

        XCTAssertTrue(
            prompt.hasPrefix(
                "You are Big Mike. You are talking to Rich over walkie talkie. You respond to the statement that comes over the walkie-talkie signal."
            )
        )
        XCTAssertTrue(prompt.contains("{{characterBackstory}}"))
        XCTAssertTrue(prompt.contains("{{promptContext}}"))
        XCTAssertTrue(prompt.contains("{{prerecordingTranscript}}"))
        XCTAssertTrue(prompt.contains("{{userInput}}"))
        XCTAssertTrue(
            prompt.contains(
                "This is the statement you are responding to. This signal came over walkie-talkie."
            )
        )
        XCTAssertFalse(prompt.contains("{{characterProfile}}"))
        XCTAssertFalse(prompt.contains("Do not mention audio"))
        XCTAssertFalse(prompt.contains("Do not include extra keys"))
        XCTAssertEqual(
            TuringConversationPromptVariant
                .forScriptPointID("prologue.scriptPoint05"),
            .scriptPoint05
        )
        XCTAssertEqual(
            TuringConversationPromptVariant
                .forScriptPointID("prologue.scriptPoint01"),
            .standard
        )
    }

    func testConversationUsesExactCurrentPromptVoiceStoryContext()
        async throws {
        let descriptorStore = TuringVoicePromptTriggerStore()
        let point01 = try descriptorStore.descriptor(
            id: "prologue.bigMike.scriptPoint01.followUp.001"
        )
        let point03 = try descriptorStore.descriptor(
            id: "prologue.bigMike.scriptPoint03.followUp.001"
        )
        let point01Context =
            TuringPromptVoiceStoryContextBuilder.standard(point01)
        let point03Context =
            TuringPromptVoiceStoryContextBuilder.standard(point03)

        XCTAssertTrue(point01Context.storyContext.contains(point01.intent))
        XCTAssertFalse(point01Context.storyContext.contains(point01.emotion))
        XCTAssertTrue(point03Context.storyContext.contains(point03.intent))
        XCTAssertFalse(point03Context.storyContext.contains(point03.emotion))
        XCTAssertNotEqual(
            point01Context.storyContext,
            point03Context.storyContext
        )

        let point04 = try descriptorStore.descriptor(
            id: "prologue.rich.scriptPoint04.followUp.001"
        )
        let point04Context =
            TuringPromptVoiceStoryContextBuilder.standard(point04)
        XCTAssertEqual(
            point04Context.storyContext,
            """
            Story Intent:
            I can't believe this thing is laying in my room. It's not a person anymore it's a monster. I am still freaking out. We need the police. But police services have been down for weeks. I need to get this thing out of here
            """
        )
        XCTAssertFalse(point04Context.storyContext.contains("Continue after"))
        XCTAssertFalse(point04Context.storyContext.contains("Emotional tone:"))

        let store = TuringConversationInputStore()
        await store.updatePromptVoiceStoryContext(
            point01Context.storyContext,
            for: TuringDialogueThreadIdentity.bigMikeRich
        )
        await store.updatePromptVoiceStoryContext(
            point03Context.storyContext,
            for: TuringDialogueThreadIdentity.bigMikeRich
        )
        let active = await store.promptVoiceStoryContext(
            for: TuringDialogueThreadIdentity.bigMikeRich
        )

        XCTAssertEqual(active, point03Context.storyContext)
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

        XCTAssertTrue(source.contains("promptVoiceStoryContext"))
        XCTAssertFalse(source.contains("promptVoiceSeed"))
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
