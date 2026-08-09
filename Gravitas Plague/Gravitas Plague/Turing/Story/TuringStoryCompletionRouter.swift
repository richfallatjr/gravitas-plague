import Foundation

@MainActor
final class TuringStoryCompletionRouter: TuringStoryCompletionEventSink {
    weak var prologue: (any TuringStoryCompletionEventSink)?
    weak var chapter01: (any TuringStoryCompletionEventSink)?
    weak var chapter02: (any TuringStoryCompletionEventSink)?

    init(
        prologue: (any TuringStoryCompletionEventSink)? = nil,
        chapter01: (any TuringStoryCompletionEventSink)? = nil,
        chapter02: (any TuringStoryCompletionEventSink)? = nil
    ) {
        self.prologue = prologue
        self.chapter01 = chapter01
        self.chapter02 = chapter02
    }

    func scriptPointCompleted(
        _ event: TuringScriptPointCompletionEvent
    ) async throws -> TuringStoryCompletionDisposition {
        if event.scriptPointID.hasPrefix("prologue.") {
            guard let prologue else {
                throw TuringRuntimeError.invalidConfig(
                    "No Prologue completion owner is installed."
                )
            }
            return try await prologue.scriptPointCompleted(event)
        }

        if event.scriptPointID.hasPrefix("chapter01.") {
            guard let chapter01 else {
                throw TuringRuntimeError.invalidConfig(
                    "No Chapter 01 completion owner is installed."
                )
            }
            return try await chapter01.scriptPointCompleted(event)
        }

        if event.scriptPointID.hasPrefix("chapter02.") {
            guard let chapter02 else {
                throw TuringRuntimeError.invalidConfig(
                    "No Chapter 02 completion owner is installed."
                )
            }
            return try await chapter02.scriptPointCompleted(event)
        }

        throw TuringRuntimeError.invalidConfig(
            "No Story completion owner for \(event.scriptPointID)."
        )
    }

    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        if event.parentScriptPointID.hasPrefix("prologue.") {
            guard let prologue else {
                throw TuringRuntimeError.invalidConfig(
                    "No Prologue conversation completion owner is installed."
                )
            }
            try await prologue.conversationPlaybackCompleted(event)
            return
        }

        if event.parentScriptPointID.hasPrefix("chapter01.") {
            guard let chapter01 else {
                throw TuringRuntimeError.invalidConfig(
                    "No Chapter 01 conversation completion owner is installed."
                )
            }
            try await chapter01.conversationPlaybackCompleted(event)
            return
        }

        if event.parentScriptPointID.hasPrefix("chapter02.") {
            guard let chapter02 else {
                throw TuringRuntimeError.invalidConfig(
                    "No Chapter 02 conversation completion owner is installed."
                )
            }
            try await chapter02.conversationPlaybackCompleted(event)
            return
        }

        throw TuringRuntimeError.invalidConfig(
            "No Story conversation completion owner for \(event.parentScriptPointID)."
        )
    }
}
