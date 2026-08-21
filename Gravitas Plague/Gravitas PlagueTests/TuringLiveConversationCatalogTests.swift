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

    func testFixedSurfaceTargetPolicy() {
        XCTAssertTrue(
            TuringConversationSurfacePolicy.validates(
                target: .rich,
                for: .dadFrame
            )
        )
        XCTAssertTrue(
            TuringConversationSurfacePolicy.validates(
                target: .broadcaster,
                for: .crankRadio
            )
        )
        XCTAssertTrue(
            TuringConversationSurfacePolicy.validates(
                target: .bigMike,
                for: .walkie
            )
        )
        XCTAssertFalse(
            TuringConversationSurfacePolicy.validates(
                target: .rich,
                for: .walkie
            )
        )
        XCTAssertTrue(
            TuringConversationSurfacePolicy.validates(
                target: .dad,
                for: .hamReceiver
            )
        )
        XCTAssertTrue(
            TuringConversationSurfacePolicy.validates(
                target: .catEye81,
                for: .hamReceiver
            )
        )
        XCTAssertFalse(
            TuringConversationSurfacePolicy.validates(
                target: .rich,
                for: .hamReceiver
            )
        )
    }

    func testRichWalkieBeforeFirstMikeUsesNextMikePromptVoice() throws {
        let store = try TuringLiveConversationCatalogStore()
        let richMoment = try XCTUnwrap(
            store.entry(
                scriptPointID: "chapter01.walkie.rich.script06",
                authoredPrerecordingID: "chapter01.walkie.rich.script06.001"
            )
        )
        let selection = try TuringConversationTargetContextResolver(
            catalog: store.routingCatalog
        ).resolve(episodeID: .chapter01, currentMoment: richMoment)

        XCTAssertEqual(selection.targetCharacterID, .bigMike)
        XCTAssertEqual(selection.position, .next)
        XCTAssertEqual(selection.selectedMoment.speakerCharacterID, .bigMike)
        XCTAssertEqual(
            selection.selectedMoment.scriptPointID,
            "chapter01.walkie.bigMike.script07"
        )
    }

    func testRichWalkieAfterMikeUsesLatestPriorMikePromptVoice() throws {
        let store = try TuringLiveConversationCatalogStore()
        let richMoment = try XCTUnwrap(
            store.entry(
                scriptPointID: "chapter01.walkie.rich.script08",
                authoredPrerecordingID: "chapter01.walkie.rich.script08.001"
            )
        )
        let selection = try TuringConversationTargetContextResolver(
            catalog: store.routingCatalog
        ).resolve(episodeID: .chapter01, currentMoment: richMoment)

        XCTAssertEqual(selection.targetCharacterID, .bigMike)
        XCTAssertEqual(selection.position, .currentOrPrior)
        XCTAssertEqual(
            selection.selectedMoment.scriptPointID,
            "chapter01.walkie.bigMike.script07"
        )
    }

    func testArbiterRetainsAndAtomicallyReplacesSurfaceSlot() async throws {
        let arbiter = StoryInteractionArbiter.shared
        await arbiter.reset(reason: "test.routing.replace")
        let generation = await arbiter.beginConversationChapter(
            episodeID: .prologue,
            segmentID: "test.segment",
            reason: "test"
        )
        let first = makeSeed(
            parentSequenceID: UUID(),
            parentFlowInstanceID: UUID(),
            retention: .untilExplicitInvalidation
        ).withMicrophoneGeneration(generation)
        let second = makeSeed(
            parentSequenceID: UUID(),
            parentFlowInstanceID: UUID(),
            retention: .untilExplicitInvalidation
        ).withMicrophoneGeneration(generation)

        try await arbiter.latchConversationMicrophone(
            slot: makeSlot(first),
            expectedGeneration: generation,
            reason: "test.first"
        )
        try await arbiter.latchConversationMicrophone(
            slot: makeSlot(second),
            expectedGeneration: generation,
            reason: "test.second"
        )

        let slots = await arbiter.currentLatchedConversationSlots()
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[.walkie]?.seed.seedID, second.seedID)
    }

    func testBattleClaimClearsEveryLatchedMicrophone() async throws {
        let arbiter = StoryInteractionArbiter.shared
        await arbiter.reset(reason: "test.routing.battle")
        let generation = await arbiter.beginConversationChapter(
            episodeID: .prologue,
            segmentID: "test.segment",
            reason: "test"
        )
        let seed = makeSeed(
            parentSequenceID: UUID(),
            parentFlowInstanceID: UUID(),
            retention: .untilExplicitInvalidation
        ).withMicrophoneGeneration(generation)
        try await arbiter.latchConversationMicrophone(
            slot: makeSlot(seed),
            expectedGeneration: generation,
            reason: "test"
        )

        let lease = try await arbiter.claimBattle(
            battleInstanceID: UUID(),
            source: "test"
        )
        let slotsAfterBattleClaim =
            await arbiter.currentLatchedConversationSlots()
        XCTAssertTrue(slotsAfterBattleClaim.isEmpty)
        await arbiter.release(lease, reason: "test")
    }

    func testStaleGenerationCannotRelatchAfterChapterBoundary() async throws {
        let arbiter = StoryInteractionArbiter.shared
        await arbiter.reset(reason: "test.routing.stale")
        let oldGeneration = await arbiter.beginConversationChapter(
            episodeID: .prologue,
            segmentID: "test.segment",
            reason: "test.old"
        )
        let seed = makeSeed(
            parentSequenceID: UUID(),
            parentFlowInstanceID: UUID(),
            retention: .untilExplicitInvalidation
        ).withMicrophoneGeneration(oldGeneration)
        _ = await arbiter.beginConversationChapter(
            episodeID: .chapter01,
            segmentID: "chapter01.beforeRobotAntigen",
            reason: "test.new"
        )

        do {
            try await arbiter.latchConversationMicrophone(
                slot: makeSlot(seed),
                expectedGeneration: oldGeneration,
                reason: "test.stale"
            )
            XCTFail("A stale PR start must not restore a cleared microphone.")
        } catch {
            let slotsAfterStaleLatch =
                await arbiter.currentLatchedConversationSlots()
            XCTAssertTrue(slotsAfterStaleLatch.isEmpty)
        }
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
            episodeID: .prologue,
            segmentID: "test.segment",
            sourceMomentID: "test.moment",
            microphoneGeneration: 1,
            parentFlowSequenceID: parentSequenceID,
            parentFlowInstanceID: parentFlowInstanceID,
            parentPlaybackRunID: "origin.playback",
            scriptPointID: "test.scriptPoint",
            authoredMediaItemID: "test.pr",
            authoredMediaRole: .primaryPrerecording,
            interactionSurface: interactionSurface,
            immediateDeviceContext: .init(
                momentID: "test.moment",
                scriptPointID: "test.scriptPoint",
                prerecordingID: "test.pr",
                speakerCharacterID: .rich,
                transcript: "Test transcript.",
                transcriptProof: .init(
                    resourcePath: "test.pr.json",
                    byteCount: 1,
                    sha256: "pr"
                )
            ),
            targetContext: .init(
                targetCharacterID: .bigMike,
                selectedMomentID: "test.targetMoment",
                selectionPosition: .currentOrPrior,
                voicePromptID: "test.promptVoice",
                voicePromptProof: .init(
                    resourcePath: "test.promptVoice.json",
                    byteCount: 1,
                    sha256: "prompt"
                ),
                characterProfileID: "big_mike",
                listenerProfileID: "rich",
                voiceID: "big_mike_base_clone_v1",
                conversationKey: "dialogue.big_mike.rich",
                outputRoute: .walkieSpatial,
                promptVariant: .standard,
                promptVoiceStoryContext: "Test story context.",
                priorTargetTranscript: "Mike spoke earlier."
            ),
            backgroundMusic: nil,
            catalogRetention: retention
        )
    }

    private func makeSlot(
        _ seed: TuringLiveConversationSeed
    ) -> TuringLatchedMicrophoneSlot {
        TuringLatchedMicrophoneSlot(
            slotID: UUID(),
            generation: seed.microphoneGeneration,
            episodeID: seed.episodeID,
            segmentID: seed.segmentID,
            surface: seed.interactionSurface,
            activationMomentID: seed.sourceMomentID,
            targetCharacterID: seed.targetContext.targetCharacterID,
            seed: seed
        )
    }
}
