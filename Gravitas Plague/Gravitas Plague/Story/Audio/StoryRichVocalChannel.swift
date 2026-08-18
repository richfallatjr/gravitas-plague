import Foundation

@MainActor
protocol StoryRichVocalChannelControlling: AnyObject {
    func beginBattleSpeech(
        battleInstanceID: UUID,
        cueID: String,
        playbackID: UUID
    ) -> StoryRichBattleSpeechToken

    func endBattleSpeech(
        token: StoryRichBattleSpeechToken,
        reason: String
    )

    func requirePlayerDeathVocalResources() throws

    func startRandomPlayerDeathVocal(
        purpose: StoryPlayerDeathVocalPurpose,
        ownerID: String
    ) throws -> StoryPlayerDeathVocalToken

    func stopPlayerDeathVocal(
        token: StoryPlayerDeathVocalToken,
        reason: String
    )

    func relinquishPlayerDeathVocalToNaturalCompletion(
        token: StoryPlayerDeathVocalToken,
        reason: String
    )

    var playerDamageVocalSuppressed: Bool { get }
}

nonisolated struct StoryRichBattleSpeechToken: Sendable, Equatable, Hashable {
    let id: UUID
    let battleInstanceID: UUID
    let cueID: String
    let playbackID: UUID
}

nonisolated enum StoryPlayerDeathVocalPurpose: String, Sendable, Equatable {
    case actualPlayerDeath
    case chapter03TunnelBridge
}

nonisolated struct StoryPlayerDeathVocalToken: Sendable, Equatable, Hashable {
    let id: UUID
    let purpose: StoryPlayerDeathVocalPurpose
    let ownerID: String
    let fileName: String
    let durationSeconds: Double
    let playerObjectID: String
}
