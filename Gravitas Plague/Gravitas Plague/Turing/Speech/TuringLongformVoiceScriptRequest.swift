import Foundation

struct TuringPlaybackTarget: Sendable, Hashable {
    let id: String
}

struct TuringLongformVoiceScriptRequest: Sendable, Hashable {
    let requestID: String
    let sourceText: String
    let speakerID: String
    let voiceID: String
    let defaultEmotion: String
    let playbackTarget: TuringPlaybackTarget?
    let debugLabel: String?

    init(
        requestID: String,
        sourceText: String,
        speakerID: String,
        voiceID: String,
        defaultEmotion: String,
        playbackTarget: TuringPlaybackTarget? = nil,
        debugLabel: String? = nil
    ) {
        self.requestID = requestID
        self.sourceText = sourceText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        self.speakerID = speakerID
        self.voiceID = voiceID
        self.defaultEmotion = defaultEmotion
        self.playbackTarget = playbackTarget
        self.debugLabel = debugLabel
    }
}
