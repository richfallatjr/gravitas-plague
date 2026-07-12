#if DEBUG || GR_TURING_DIAGNOSTICS
import Foundation

enum TuringPrerecordingSeededPromptRunner {
    static func runBigMikeRichContact(
        seedStore: TuringConversationSeedStore
    ) async -> TuringNativeQwenRunResult {
        let result =
            await TuringEpisodeFlowController
                .shared
                .start(
                    scriptPointID:
                        "prologue.scriptPoint01",
                    trigger: .userPlay
                )

        switch result {
        case .succeeded(let message):
            return .succeeded(message)
        case .failed(let message):
            return .failed(message)
        }
    }
}
#endif
