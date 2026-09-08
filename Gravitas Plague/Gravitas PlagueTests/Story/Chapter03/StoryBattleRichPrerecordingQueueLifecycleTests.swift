import XCTest

@testable import Gravitas_Plague

@MainActor
final class StoryBattleRichPrerecordingQueueLifecycleTests: XCTestCase {
    func testAllRunsCancellationPreservesLifetimePlaybackStartObserver() {
        let queue = StoryBattleRichPrerecordingQueue(
            richVocalChannel: PlaybackObserverRichVocalChannelFake()
        )
        var receivedEvent: StoryBattlePrerecordingStartedEvent?
        queue.onActualPlaybackStarted = { receivedEvent = $0 }

        // Chapter-wide reset paths call the default nil/all-runs form before
        // Chapter 3 begins. That cancellation must not disconnect the queue's
        // owner-installed observer for the later Mike surrender playback.
        queue.cancel(reason: "preChapterReset")

        XCTAssertNotNil(queue.onActualPlaybackStarted)

        let event = StoryBattlePrerecordingStartedEvent(
            battleInstanceID: UUID(),
            cueID: "mikeSurrender",
            prerecordingID: "rich-mike-battle-02",
            playbackID: UUID(),
            durationSeconds: 53.123651
        )
        queue.onActualPlaybackStarted?(event)

        XCTAssertEqual(receivedEvent, event)
    }
}

@MainActor
private final class PlaybackObserverRichVocalChannelFake:
    StoryRichVocalChannelControlling
{
    var playerDamageVocalSuppressed: Bool { false }

    func beginBattleSpeech(
        battleInstanceID: UUID,
        cueID: String,
        playbackID: UUID
    ) -> StoryRichBattleSpeechToken {
        StoryRichBattleSpeechToken(
            id: UUID(),
            battleInstanceID: battleInstanceID,
            cueID: cueID,
            playbackID: playbackID
        )
    }

    func endBattleSpeech(
        token: StoryRichBattleSpeechToken,
        reason: String
    ) {}

    func requirePlayerDeathVocalResources() throws {}

    func startRandomPlayerDeathVocal(
        purpose: StoryPlayerDeathVocalPurpose,
        ownerID: String
    ) throws -> StoryPlayerDeathVocalToken {
        StoryPlayerDeathVocalToken(
            id: UUID(),
            purpose: purpose,
            ownerID: ownerID,
            fileName: "unused.wav",
            durationSeconds: 0,
            playerObjectID: "unused"
        )
    }

    func stopPlayerDeathVocal(
        token: StoryPlayerDeathVocalToken,
        reason: String
    ) {}

    func relinquishPlayerDeathVocalToNaturalCompletion(
        token: StoryPlayerDeathVocalToken,
        reason: String
    ) {}
}
