import Foundation

enum TuringConversationContextRehydrator {
    static func rehydrate(
        terminalScriptPointID: String
    ) async throws {
        let descriptor = try TuringFlowDescriptorStore().require(
            terminalScriptPointID
        )
        let prerecording = try TuringPrerecordingStore().descriptor(
            id: descriptor.transmission.prerecordingID
        )
        guard prerecording.transcriptMode == .manual,
              !prerecording.transcript.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              let promptID = descriptor.transmission.voicePromptID else {
            throw TuringRuntimeError.invalidConfig(
                "\(terminalScriptPointID) requires an authored PR transcript and promptVoice descriptor."
            )
        }

        let prompt = try TuringVoicePromptTriggerStore().descriptor(id: promptID)
        let context = TuringPromptVoiceStoryContextBuilder.standard(prompt)
        let key = descriptor.transmission.conversationKey
        await TuringConversationInputStore.shared.updatePrerecording(
            id: prerecording.prerecordingID,
            transcript: prerecording.transcript,
            for: key
        )
        await TuringConversationInputStore.shared.updatePromptVoiceStoryContext(
            context.storyContext,
            for: key
        )
        await TuringConversationInputStore.shared.updatePromptVariant(
            .forScriptPointID(terminalScriptPointID),
            for: key
        )
        await TuringConversationInputStore.shared.updateCharacterProfileID(
            prompt.characterProfileID,
            for: key
        )
        print("""
        [TuringContinuation] Chapter conversation context rehydrated
          scriptPointID: \(terminalScriptPointID)
          conversationKey: \(key)
          characterProfileID: \(prompt.characterProfileID)
          authoredPR: true
          generatedHistoryIncluded: false
        """)
    }
}
