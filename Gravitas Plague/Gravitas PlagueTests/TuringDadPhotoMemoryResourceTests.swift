import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringDadPhotoMemoryResourceTests: XCTestCase {
    private let scriptPointID =
        "prologue.dadPhotoMemory.001"
    private let expectedStoryIntent =
        "I’m looking at an old wedding photo of Dad and me from about twenty years ago. We had a good relationship. Dad was an engineer, and he taught me how to understand machines, build things, troubleshoot electronics, and work with tools and gadgets. A lot of what is keeping me alive now came from him. He disappeared early in the outbreak, and I still have no reliable idea what happened to him. I’m scared he may be gone, but I have not accepted that. Getting the ham radio working may be my best chance to search for him or hear something useful. I’m trying to talk about the practical things he taught me because admitting how much I miss him is harder."

    func testDadPhotoDescriptorUsesSharedRichPipeline() throws {
        let descriptor = try TuringFlowDescriptorStore()
            .require(scriptPointID)
        XCTAssertEqual(
            descriptor.transmission.characterID,
            "rich"
        )
        XCTAssertEqual(
            descriptor.transmission.outputRoute,
            .roomGlobal
        )
        XCTAssertEqual(
            descriptor.transmission.effectiveInteractionSurface,
            .dadFrame
        )
        XCTAssertEqual(
            descriptor.transmission.fillerMode,
            .continuousFromPrerecordingToGenerated
        )
        XCTAssertEqual(
            descriptor.transmission.computeStart,
            .foundationBeforePrerecording
        )
        XCTAssertFalse(
            descriptor.transmission.commSFX
                .openBeforePrerecording
        )
        XCTAssertFalse(
            descriptor.transmission.commSFX
                .sendAfterGenerated
        )
    }

    func testDadPhotoPromptUsesExactSingleAuthoredContext() throws {
        let prompt = try TuringVoicePromptTriggerStore()
            .descriptor(
                id:
                    "prologue.rich.dadPhotoMemory.followUp.001"
            )
        XCTAssertEqual(prompt.intent, expectedStoryIntent)
        XCTAssertNil(prompt.promptContext)
        XCTAssertEqual(
            prompt.effectiveAuthoredStoryContext,
            expectedStoryIntent
        )
        XCTAssertEqual(
            prompt.effectivePromptTemplateID,
            .roomObjectMemory
        )
        XCTAssertEqual(
            TuringPromptVoiceStoryContextBuilder.standard(
                prompt
            ).storyContext,
            expectedStoryIntent
        )
    }

    func testDadPromptRuleSuffixMatchesStandardPromptVoice() throws {
        let standard = try promptText(
            resourcePath:
                "Turing/Prompts/voicePrompt_characterIntent.txt"
        )
        let dad = try promptText(
            resourcePath:
                "Turing/Prompts/voicePrompt_roomObjectMemory.txt"
        )
        XCTAssertEqual(
            suffixAfterOpening(standard),
            suffixAfterOpening(dad)
        )
        XCTAssertFalse(dad.contains("Father Memory Context"))
    }

    func testDadConversationLabelsPlayerStatementInScene() throws {
        let prompt = try promptText(
            resourcePath:
                "Turing/Prompts/conversationPrompt_roomObjectMemory.txt"
        )
        XCTAssertFalse(prompt.contains("User input:"))
        XCTAssertFalse(prompt.contains("user's current input"))
        XCTAssertTrue(
            prompt.contains(
                "This is the statement you are responding to. The player said this while talking with you about the photograph."
            )
        )
        XCTAssertTrue(
            prompt.contains("This is your backstory:")
        )
        XCTAssertFalse(prompt.contains("Character:"))
    }

    func testDadConversationCopiesScriptPoint05Structure() throws {
        let scriptPoint05 = try promptText(
            resourcePath:
                "Turing/Prompts/conversationPrompt_scriptPoint05.txt"
        )
        let dad = try promptText(
            resourcePath:
                "Turing/Prompts/conversationPrompt_roomObjectMemory.txt"
        )
        let expected = scriptPoint05
            .replacingOccurrences(
                of:
                    "You are Big Mike. You are talking to Rich over walkie talkie. You respond to the statement that comes over the walkie-talkie signal.",
                with:
                    "You are Rich. You are speaking aloud while looking at an old photograph of you and your father. You respond to the statement the player makes about the photograph."
            )
            .replacingOccurrences(
                of:
                    "This is the statement you are responding to. This signal came over walkie-talkie.",
                with:
                    "This is the statement you are responding to. The player said this while talking with you about the photograph."
            )
            .replacingOccurrences(
                of:
                    "This is the latest authored speech heard on this device. It may have been spoken by another person. Use it as the immediate conversational situation:",
                with:
                    "This is the latest authored speech heard at the photograph. Use it as the immediate conversational situation:"
            )
            .replacingOccurrences(
                of: "The speaker of that immediate device speech was:",
                with: "The speaker of that immediate speech was:"
            )
            .replacingOccurrences(
                of: "This is Big Mike's latest prior authored speech, when one has already occurred:",
                with: "This is Rich's latest prior authored speech, when one has already occurred:"
            )
            .replacingOccurrences(
                of: "The selected Big Mike context position is:",
                with: "The selected Rich context position is:"
            )
            .replacingOccurrences(
                of:
                    "- Respond to the statement in the walkie-talkie signal in you character's voice.",
                with:
                    "- Respond to the statement about the photograph in your character's voice."
            )
        XCTAssertEqual(dad, expected)
    }

    func testDadPhotoMediaResourcesExist() throws {
        _ = try TuringResourceLoader.resourceURL(
            resourcePath:
                "Turing/Audio/Music/dad-photo-memory-score.mp3"
        )
        _ = try TuringResourceLoader.resourceURL(
            resourcePath:
                "Turing/Audio/prerecordings/pr-rich-dad-photo-memory.mp3"
        )
    }

    func testDadMemoryMusicMatchesPostBattleVolume() throws {
        let dad = try TuringFlowDescriptorStore()
            .require(scriptPointID)
        let battle = try Battle01DefinitionStore().load()
        XCTAssertEqual(
            dad.transmission.backgroundMusic?.gainDB,
            battle.aftermathMusic.targetDecibels
        )
    }

    func testDadConversationVariantDoesNotRegressScriptPoint05() {
        XCTAssertEqual(
            TuringConversationPromptVariant.resolved(
                scriptPointID:
                    "prologue.dadPhotoMemory.001",
                promptTemplateID: .roomObjectMemory
            ),
            .roomObjectMemory
        )
        XCTAssertEqual(
            TuringConversationPromptVariant.resolved(
                scriptPointID: "prologue.scriptPoint05",
                promptTemplateID: .characterIntent
            ),
            .scriptPoint05
        )
    }

    private func promptText(
        resourcePath: String
    ) throws -> String {
        let url = try TuringResourceLoader.resourceURL(
            resourcePath: resourcePath
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func suffixAfterOpening(
        _ prompt: String
    ) -> Substring {
        guard let separator = prompt.range(of: "\n\n") else {
            return prompt[...]
        }
        return prompt[separator.upperBound...]
    }
}
