#if DEBUG || GR_TURING_DIAGNOSTICS
import Foundation

enum TuringPrerecordingSeededPromptRunner {
    static func runBigMikeRichContact(
        seedStore: TuringConversationSeedStore
    ) async -> TuringNativeQwenRunResult {
        let prerecordingID = "prologue.walkie.bigMike.richContact.001"
        let seedKey = "big_mike"

        do {
            let prerecordingStore = TuringPrerecordingStore()
            let prerecording = try prerecordingStore.descriptor(id: prerecordingID)
            let prerecordingAudioURL = try prerecordingStore.audioURL(
                for: prerecording
            )

            print("""
            [TuringPrerecordingSeed] requested
              prerecordingID: \(prerecording.prerecordingID)
              audioFile: \(prerecording.audioFile)
            """)

            await seedStore.updatePrerecording(
                id: prerecording.prerecordingID,
                transcript: prerecording.transcript,
                for: seedKey
            )

            let service = TuringDialogueService()
            print("""
            [TuringPrerecordingSeed] voicePrompt background task started
              id: voicePrompt.bigMike.afterRichContact.001
              prerecordingID: \(prerecording.prerecordingID)
              computesWhilePrerecordingPlays: true
            """)
            let voicePromptTask = Task.detached(priority: .userInitiated) {
                try await service.generateVoicePrompt(
                    VoicePromptRequest(
                        id: "voicePrompt.bigMike.afterRichContact.001",
                        speaker: "Big Mike",
                        voiceID: prerecording.voiceID,
                        voiceVariantID: prerecording.voiceVariantID,
                        characterProfileID: "big_mike",
                        intent: prerecording.voicePromptIntent,
                        emotion: prerecording.defaultEmotion,
                        prerecordingTranscript: prerecording.transcript,
                        voicePromptSeedIntent: prerecording.summary
                    )
                )
            }

            return await TuringNativeQwenHelloWorldCanary
                .runVoicePromptAfterPrerecording(
                    runID: prerecording.prerecordingID,
                    prerecordingID: prerecording.prerecordingID,
                    prerecordingAudioURL: prerecordingAudioURL,
                    voicePromptTask: voicePromptTask,
                    seedStore: seedStore,
                    seedKey: seedKey
                )
        } catch {
            print("""
            [TuringPrerecordingSeed] failed
              prerecordingID: \(prerecordingID)
              error: \(error.localizedDescription)
            """)
            return .failed(error.localizedDescription)
        }
    }
}
#endif
