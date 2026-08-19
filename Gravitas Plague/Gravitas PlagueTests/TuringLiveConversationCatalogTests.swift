import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringLiveConversationCatalogTests: XCTestCase {
    func testCatalogValidatesAgainstProductionResources() throws {
        try TuringLiveConversationCatalogValidator().validate()
    }

    func testCatalogKeysAreUnique() throws {
        let entries = try TuringLiveConversationCatalogStore().entries
        let keys = entries.map {
            "\($0.scriptPointID)|\($0.authoredPrerecordingID)"
        }

        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testScriptPoint05UsesSecondPRAndPromptVoiceStage() throws {
        let entry = try XCTUnwrap(
            TuringLiveConversationCatalogStore().entry(
                scriptPointID: "prologue.scriptPoint05",
                authoredPrerecordingID:
                    "prologue.walkie.bigMike.scriptPoint05.002"
            )
        )

        XCTAssertEqual(entry.voicePromptSource.kind, .generationPipelineStage)
        XCTAssertEqual(entry.voicePromptSource.stageID, "promptVoice")
        XCTAssertNil(entry.voicePromptSource.voicePromptID)
        XCTAssertEqual(entry.retention, .untilExplicitInvalidation)
        XCTAssertEqual(entry.interactionSurface, .walkie)
    }

    func testScriptPoint05FirstPRIsNotConversationSeed() throws {
        XCTAssertNil(
            try TuringLiveConversationCatalogStore().entry(
                scriptPointID: "prologue.scriptPoint05",
                authoredPrerecordingID:
                    "prologue.walkie.bigMike.scriptPoint05.001"
            )
        )
    }

    func testAllLiveConversationMicrophonesRemainAvailableAfterPRCompletion() throws {
        let entries = try TuringLiveConversationCatalogStore().entries

        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(
            entries.allSatisfy {
                $0.retention == .untilExplicitInvalidation
            }
        )
        XCTAssertEqual(
            Set(entries.map(\.interactionSurface)),
            Set(StoryInteractionSurfaceID.allCases)
        )
    }

    func testEveryDeviceSeedSurvivesPRAndOriginatingSequenceCompletion() async {
        let registry = TuringLiveConversationSeedRegistry()
        var expected: [StoryInteractionSurfaceID: TuringLiveConversationSeed] = [:]

        for surface in StoryInteractionSurfaceID.allCases {
            let seed = makeSeed(
                parentSequenceID: UUID(),
                parentFlowInstanceID: UUID(),
                retention: .untilExplicitInvalidation,
                interactionSurface: surface
            )
            expected[surface] = seed
            await registry.authoredItemStarted(seed: seed)
            await registry.authoredItemCompleted(seedID: seed.seedID)
            await registry.flowSequenceCompleted(
                sequenceID: seed.parentFlowSequenceID
            )
        }

        let retained = await registry.snapshot(
            allowedSurfaces: Set(StoryInteractionSurfaceID.allCases),
            hostSequenceID: UUID(),
            hostFlowInstanceID: UUID()
        )
        XCTAssertEqual(retained.seedsBySurface, expected)
    }

    func testDadPhotoScoreSurvivesResponsePlaybackStart() {
        let flowInstanceID = UUID()
        let memoryToken = StoryMemoryMusicActor.Token(
            id: UUID(),
            flowInstanceID: flowInstanceID
        )
        let liveGapToken = StoryMemoryMusicLiveGapToken(
            id: UUID(),
            flowInstanceID: flowInstanceID,
            memoryMusicToken: memoryToken
        )

        XCTAssertFalse(
            TuringLiveConversationInitialFillerToken
                .dadPhoto(liveGapToken)
                .endsWhenResponsePlaybackStarts
        )
        XCTAssertFalse(
            TuringLiveConversationInitialFillerToken
                .dadPhoto(liveGapToken)
                .mustEndBeforeSpokenCoverResumes
        )
        XCTAssertTrue(
            TuringLiveConversationInitialFillerToken
                .crankRadio(ownerID: "test")
                .endsWhenResponsePlaybackStarts
        )
        XCTAssertTrue(
            TuringLiveConversationInitialFillerToken
                .crankRadio(ownerID: "test")
                .mustEndBeforeSpokenCoverResumes
        )
        XCTAssertTrue(
            TuringLiveConversationInitialFillerToken
                .hamReceiver(ownerID: "test")
                .endsWhenResponsePlaybackStarts
        )
        XCTAssertTrue(
            TuringLiveConversationInitialFillerToken
                .hamReceiver(ownerID: "test")
                .mustEndBeforeSpokenCoverResumes
        )
        XCTAssertTrue(
            TuringLiveConversationInitialFillerToken
                .walkie(
                    TuringWalkieSendingStaticToken(
                        id: UUID(),
                        ownerID: "test",
                        handle: TuringAudioPlaybackHandle(
                            id: UUID(),
                            requestID: UUID(),
                            runID: "test",
                            route: .storyWalkie
                        )
                    )
                )
                .mustEndBeforeSpokenCoverResumes
        )
        XCTAssertFalse(
            TuringLiveConversationInitialFillerToken
                .walkie(
                    TuringWalkieSendingStaticToken(
                        id: UUID(),
                        ownerID: "test",
                        handle: TuringAudioPlaybackHandle(
                            id: UUID(),
                            requestID: UUID(),
                            runID: "test",
                            route: .storyWalkie
                        )
                    )
                )
                .endsWhenResponsePlaybackStarts
        )
    }

    func testRetainedSeedCanBorrowDifferentActiveDeviceFlowLease() throws {
        let hostSequenceID = UUID()
        let hostFlowInstanceID = UUID()
        let lease = StoryInteractionLease(
            id: UUID(),
            owner: .turingFlow(runID: hostSequenceID.uuidString)
        )
        let seed = makeSeed(
            parentSequenceID: UUID(),
            parentFlowInstanceID: UUID(),
            retention: .untilExplicitInvalidation
        )

        let validated = try TuringBorrowedAuthoredFlowLeaseValidator.requireValid(
            hostFlowSequenceID: hostSequenceID,
            hostFlowInstanceID: hostFlowInstanceID,
            parentLeaseID: lease.id,
            suppliedLease: lease,
            seed: seed
        )

        XCTAssertEqual(validated, lease)
    }

    func testShortLivedSeedCannotBorrowDifferentDeviceFlowLease() {
        let hostSequenceID = UUID()
        let lease = StoryInteractionLease(
            id: UUID(),
            owner: .turingFlow(runID: hostSequenceID.uuidString)
        )
        let seed = makeSeed(
            parentSequenceID: UUID(),
            parentFlowInstanceID: UUID(),
            retention: .currentFlowSequence
        )

        XCTAssertThrowsError(
            try TuringBorrowedAuthoredFlowLeaseValidator.requireValid(
                hostFlowSequenceID: hostSequenceID,
                hostFlowInstanceID: UUID(),
                parentLeaseID: lease.id,
                suppliedLease: lease,
                seed: seed
            )
        )
    }

    private func makeSeed(
        parentSequenceID: UUID,
        parentFlowInstanceID: UUID,
        retention: TuringLiveConversationCatalog.Entry.Retention,
        interactionSurface: StoryInteractionSurfaceID = .walkie
    ) -> TuringLiveConversationSeed {
        TuringLiveConversationSeed(
            seedID: UUID(),
            parentFlowSequenceID: parentSequenceID,
            parentFlowInstanceID: parentFlowInstanceID,
            parentPlaybackRunID: "origin.playback",
            scriptPointID: "test.scriptPoint",
            authoredMediaItemID: "test.pr",
            authoredMediaRole: .primaryPrerecording,
            prerecordingID: "test.pr",
            prerecordingTranscript: "Test transcript.",
            prerecordingProof: .init(
                resourcePath: "test.pr.json",
                byteCount: 1,
                sha256: "pr"
            ),
            voicePromptID: "test.promptVoice",
            voicePromptProof: .init(
                resourcePath: "test.promptVoice.json",
                byteCount: 1,
                sha256: "prompt"
            ),
            characterID: "big_mike",
            characterProfileID: "big_mike",
            listenerProfileID: "rich",
            voiceID: "big_mike_base_clone_v1",
            interactionSurface: interactionSurface,
            outputRoute: .walkieSpatial,
            conversationKey: "dialogue.big_mike.rich",
            promptVariant: .standard,
            promptVoiceStoryContext: "Test story context.",
            backgroundMusic: nil,
            catalogRetention: retention
        )
    }
}
