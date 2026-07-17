import Foundation

@MainActor
final class TuringPrologueCompletionCoordinator: TuringPrologueCompletionEventSink {
    private let progress: TuringStoryProgressStore
    private let battleRouter: PrologueStoryActionRouter
    private var handledEventIDs = Set<UUID>()

    init(
        progress: TuringStoryProgressStore = .shared,
        battleRouter: PrologueStoryActionRouter
    ) {
        self.progress = progress
        self.battleRouter = battleRouter
    }

    func scriptPointCompleted(_ event: TuringScriptPointCompletionEvent) async throws {
        guard handledEventIDs.contains(event.eventID) == false else { return }

        switch event.scriptPointID {
        case "prologue.scriptPoint01":
            try progress.commit(
                episodeID: .prologue,
                checkpoint: .script01PromptVoiceCompleted,
                sourceEventID: event.eventID,
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
        case "prologue.scriptPoint02":
            try progress.commit(
                episodeID: .prologue,
                checkpoint: .script02PromptVoiceCompleted,
                sourceEventID: event.eventID,
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
        case "prologue.scriptPoint03":
            try progress.commit(
                episodeID: .prologue,
                checkpoint: .script03PromptVoiceCompleted,
                sourceEventID: event.eventID,
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
            battleRouter.scriptPointCompleted(event)
        case "prologue.scriptPoint04":
            try progress.commit(
                episodeID: .prologue,
                checkpoint: .script04PromptVoiceCompleted,
                sourceEventID: event.eventID,
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
        case "prologue.scriptPoint05":
            try progress.commit(
                episodeID: .prologue,
                checkpoint: .script05PromptVoiceCompleted,
                sourceEventID: event.eventID,
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
        default:
            break
        }
        handledEventIDs.insert(event.eventID)
    }

    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        guard handledEventIDs.contains(event.eventID) == false else {
            return
        }
        let checkpoint: TuringPrologueCheckpoint
        switch event.parentScriptPointID {
        case "prologue.scriptPoint01":
            checkpoint = .script01ConversationVoiceCompleted
        case "prologue.scriptPoint04":
            checkpoint = .script04ConversationVoiceCompleted
        default:
            return
        }
        try progress.commit(
            episodeID: .prologue,
            checkpoint: checkpoint,
            sourceEventID: event.eventID,
            contentRevision: TuringStoryProgressStore.prologueContentRevision
        )
        handledEventIDs.insert(event.eventID)
    }

    func reset(reason: String) {
        handledEventIDs.removeAll(keepingCapacity: false)
        battleRouter.reset(reason: reason)
    }
}
