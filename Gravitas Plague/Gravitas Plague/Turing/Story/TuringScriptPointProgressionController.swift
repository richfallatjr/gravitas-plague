import Foundation

actor TuringScriptPointProgressionController {
    static let shared = TuringScriptPointProgressionController()

    private enum State: String {
        case waitingForFirstCustomMessage
        case runningScriptPoint02And03
        case completed
    }

    private var state: State = .waitingForFirstCustomMessage

    func triggerAfterFirstSuccessfulWalkieCustomMessage(
        seedStore: TuringConversationSeedStore = .shared
    ) async -> TuringVoiceRunResult? {
        guard state == .waitingForFirstCustomMessage else {
            print("""
            [TuringScriptPoint02Trigger] ignored
              reason: firstSuccessfulWalkieCustomMessageAlreadyConsumed
              state: \(state.rawValue)
            """)
            return nil
        }

        state = .runningScriptPoint02And03
        print("""
        [TuringScriptPoint02Trigger] fired
          source: scriptPoint01ConversationVoicePlayback
          scriptPoint01ConversationVoicePlaybackCompleted: true
          completionSource: TuringStoryWalkiePlaybackCoordinator.waitUntilPlaybackFinished
          delayBeforeScriptPoint02Seconds: 2.000
        """)

        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            state = .waitingForFirstCustomMessage
            print("""
            [TuringScriptPoint02Trigger] cancelled during post-playback delay
              nextState: \(state.rawValue)
            """)
            return .failed(
                "ScriptPoint02 trigger cancelled during its two-second delay."
            )
        }

        print("""
        [TuringScriptPoint02Trigger] post-playback delay completed
          source: scriptPoint01ConversationVoicePlayback
          elapsedSeconds: 2.000
        """)

        let result = await TuringScriptPoint02And03FlowController.shared.run(
            seedStore: seedStore
        )

        if result.succeeded {
            state = .completed
        } else {
            // A missing authored asset or transient model failure can be retried
            // after the next successful ScriptPoint01 conversationVoice run. The
            // manual debug control remains available for direct testing.
            state = .waitingForFirstCustomMessage
        }

        print("""
        [TuringScriptPoint02Trigger] flow finished
          succeeded: \(result.succeeded)
          nextState: \(state.rawValue)
          result: \(result.pickerStatus)
        """)
        return result
    }

    func markCompletedByManualRun() {
        state = .completed
        print("""
        [TuringScriptPoint02Trigger] marked completed
          source: manualDebugRun
        """)
    }
}
