import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringSpokenPresentationContextResolverTests: XCTestCase {
    func testAuthoredBigMikeResolvesFromDescriptorSpeaker() {
        let identity = makeIdentity(character: .bigMike)
        let origin = ContinuousClock.now
        let handle = makeHandle(runID: identity.playbackRunID)
        let item = makeItem(
            speaker: .bigMike,
            entry: makeEntry(speaker: .bigMike, target: .rich)
        )

        guard case .resolved(let context) =
                TuringSpokenPresentationContextResolver.authored(
                    item: item,
                    flowIdentity: identity,
                    playbackHandle: handle,
                    clockOrigin: origin
                ) else {
            return XCTFail("Expected Big Mike authored context.")
        }

        XCTAssertEqual(context.speakerCharacterID, .bigMike)
        XCTAssertEqual(context.interactionSurface, .walkie)
        XCTAssertEqual(context.clockOrigin, origin)
    }

    func testAuthoredRichWalkieDoesNotUseConversationTargetAsSpeaker() {
        let identity = makeIdentity(character: .rich)
        let entry = makeEntry(
            speaker: .rich,
            target: .bigMike,
            surface: .walkie
        )
        let item = makeItem(speaker: .rich, entry: entry)

        guard case .resolved(let context) =
                TuringSpokenPresentationContextResolver.authored(
                    item: item,
                    flowIdentity: identity,
                    playbackHandle: makeHandle(
                        runID: identity.playbackRunID,
                        route: .richHeadTracked
                    ),
                    clockOrigin: ContinuousClock.now
                ) else {
            return XCTFail("Expected Rich walkie context.")
        }

        XCTAssertEqual(entry.conversationTargetCharacterID, .bigMike)
        XCTAssertEqual(context.speakerCharacterID, .rich)
        XCTAssertEqual(context.interactionSurface, .walkie)
        XCTAssertEqual(context.playbackHandle.route, .richHeadTracked)
    }

    func testCatalogSpeakerMismatchIsSuppressed() {
        assertAuthoredSuppressed(
            item: makeItem(
                speaker: .rich,
                entry: makeEntry(speaker: .bigMike, target: .rich)
            ),
            identity: makeIdentity(character: .rich),
            reasonPrefix: "authoredSpeakerCatalogMismatch"
        )
    }

    func testCatalogSurfaceMismatchIsSuppressed() {
        assertAuthoredSuppressed(
            item: makeItem(
                speaker: .rich,
                entry: makeEntry(
                    speaker: .rich,
                    target: .bigMike,
                    surface: .dadFrame
                )
            ),
            identity: makeIdentity(character: .rich),
            reasonPrefix: "authoredSurfaceCatalogMismatch"
        )
    }

    func testInvalidDescriptorSpeakerIsSuppressed() {
        let identity = makeIdentity(character: .bigMike)
        let item = TuringAuthoredMediaItem(
            scriptPointID: identity.scriptPointID,
            id: "test.pr",
            role: .primaryPrerecording,
            fileURL: URL(fileURLWithPath: "/tmp/test-pr.wav"),
            speakerCharacterID: "not_a_character"
        )
        assertAuthoredSuppressed(
            item: item,
            identity: identity,
            reasonPrefix: "unknownAuthoredSpeaker"
        )
    }

    func testGeneratedPromptVoiceUsesFlowSpeaker() {
        assertGeneratedSpeaker(.bigMike)
    }

    func testGeneratedConversationVoiceUsesTargetIdentity() {
        assertGeneratedSpeaker(.catEye81)
    }

    func testStaleHandleRunIDIsSuppressed() {
        let identity = makeIdentity(character: .bigMike)
        let result = TuringSpokenPresentationContextResolver.generated(
            segmentIndex: 0,
            flowIdentity: identity,
            playbackHandle: makeHandle(runID: "stale.run"),
            clockOrigin: ContinuousClock.now
        )
        guard case .suppressed(let reason) = result else {
            return XCTFail("Expected stale run suppression.")
        }
        XCTAssertEqual(reason, "runIdentityMismatch")
    }

    private func assertGeneratedSpeaker(
        _ speaker: TuringConversationCharacterID
    ) {
        let identity = makeIdentity(character: speaker)
        let result = TuringSpokenPresentationContextResolver.generated(
            segmentIndex: 3,
            flowIdentity: identity,
            playbackHandle: makeHandle(runID: identity.playbackRunID),
            clockOrigin: ContinuousClock.now
        )
        guard case .resolved(let context) = result else {
            return XCTFail("Expected generated context for \(speaker.rawValue).")
        }
        XCTAssertEqual(context.speakerCharacterID, speaker)
        XCTAssertEqual(context.source, .generated(segmentIndex: 3))
    }

    private func assertAuthoredSuppressed(
        item: TuringAuthoredMediaItem,
        identity: TuringFlowIdentity,
        reasonPrefix: String
    ) {
        let result = TuringSpokenPresentationContextResolver.authored(
            item: item,
            flowIdentity: identity,
            playbackHandle: makeHandle(runID: identity.playbackRunID),
            clockOrigin: ContinuousClock.now
        )
        guard case .suppressed(let reason) = result else {
            return XCTFail("Expected authored suppression.")
        }
        XCTAssertTrue(reason.hasPrefix(reasonPrefix), reason)
    }

    private func makeIdentity(
        character: TuringConversationCharacterID
    ) -> TuringFlowIdentity {
        TuringFlowIdentity(
            scriptPointID: "test.scriptPoint",
            characterID: character.rawValue,
            prerecordingID: "test.pr",
            voicePromptID: "test.prompt",
            interactionSurface: .walkie,
            playbackRunID: "test.run.\(character.rawValue)"
        )
    }

    private func makeHandle(
        runID: String,
        route: TuringAudioRouteID = .storyWalkie
    ) -> TuringAudioPlaybackHandle {
        TuringAudioPlaybackHandle(
            id: UUID(),
            requestID: UUID(),
            runID: runID,
            route: route
        )
    }

    private func makeItem(
        speaker: TuringConversationCharacterID,
        entry: TuringLiveConversationCatalog.Entry?
    ) -> TuringAuthoredMediaItem {
        TuringAuthoredMediaItem(
            scriptPointID: "test.scriptPoint",
            id: "test.pr",
            role: .primaryPrerecording,
            fileURL: URL(fileURLWithPath: "/tmp/test-pr.wav"),
            speakerCharacterID: speaker.rawValue,
            liveConversationCatalogEntry: entry
        )
    }

    private func makeEntry(
        speaker: TuringConversationCharacterID,
        target: TuringConversationCharacterID,
        surface: StoryInteractionSurfaceID = .walkie
    ) -> TuringLiveConversationCatalog.Entry {
        TuringLiveConversationCatalog.Entry(
            momentID: "test.moment",
            segmentID: "test.segment",
            narrativeOrdinal: 0,
            scriptPointID: "test.scriptPoint",
            authoredPrerecordingID: "test.pr",
            voicePromptSource: .init(
                kind: .transmission,
                stageID: nil,
                voicePromptID: "test.prompt"
            ),
            interactionSurface: surface,
            speakerCharacterID: speaker,
            conversationTargetCharacterID: target,
            retention: .currentAuthoredItem
        )
    }
}
