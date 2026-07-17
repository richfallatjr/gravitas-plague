import Foundation
import simd
import XCTest
@testable import Gravitas_Plague

@MainActor
final class TuringStoryEpisodeContinuationTests: XCTestCase {
    func testProductionCatalogStartsWithPrologueAndApprovedTitle() {
        let episodes = TuringEpisodeCatalog.productionEpisodes
        XCTAssertEqual(episodes.map(\.id), [.prologue])
        XCTAssertEqual(episodes[0].title, "Prologue")
        XCTAssertEqual(
            episodes[0].subtitle,
            "They are not human—they are monsters"
        )
        XCTAssertEqual(episodes[0].stripArtwork, .prologueStrip)
    }

    func testPlateGeometryPreservesNormalizedAperture() {
        let reference = TuringEpisodePlateGeometry.referenceSize
        let layout = TuringEpisodePlateGeometry.layout(in: reference)
        let aperture = TuringEpisodePlateGeometry.transparentWindowNormalized

        XCTAssertEqual(layout.plateFrame, CGRect(origin: .zero, size: reference))
        XCTAssertEqual(layout.contentFrame.minX, reference.width * aperture.minX, accuracy: 0.001)
        XCTAssertEqual(layout.contentFrame.minY, reference.height * aperture.minY, accuracy: 0.001)
        XCTAssertEqual(layout.contentFrame.width, reference.width * aperture.width, accuracy: 0.001)
        XCTAssertEqual(layout.contentFrame.height, reference.height * aperture.height, accuracy: 0.001)
        XCTAssertTrue(layout.plateFrame.contains(layout.contentFrame))
    }

    func testProgressRoundTripsEverySupportedCheckpoint() throws {
        for checkpoint in TuringPrologueCheckpoint.allCases
            where checkpoint != .notStarted &&
                checkpoint <= .latestSupportedContinuation {
            let (store, defaults, suiteName) = makeProgressStore()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let committed = try store.commit(
                episodeID: .prologue,
                checkpoint: checkpoint,
                sourceEventID: UUID(),
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
            let reloaded = TuringStoryProgressStore(defaults: defaults)

            XCTAssertEqual(reloaded.snapshot, committed)
            XCTAssertTrue(reloaded.canContinue)
            XCTAssertNotNil(defaults.string(forKey: TuringStoryProgressStore.Key.snapshot))
        }
    }

    func testLaterCheckpointIsCappedAtBattle01Start() throws {
        let (store, defaults, suiteName) = makeProgressStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let committed = try store.commit(
            episodeID: .prologue,
            checkpoint: .script05PromptVoiceCompleted,
            sourceEventID: UUID(),
            contentRevision: TuringStoryProgressStore.prologueContentRevision
        )

        XCTAssertEqual(committed.checkpoint, .script03PromptVoiceCompleted)
        let destination = try TuringStoryDestinationPlanner.destination(for: committed)
        XCTAssertEqual(destination.checkpoint, .script03PromptVoiceCompleted)
        XCTAssertEqual(destination.walkieAction, .microphone)
        XCTAssertEqual(destination.battleState, .battle01Start)
        XCTAssertEqual(destination.mediaState, .battle01)
    }

    func testPreviouslySavedLaterCheckpointMigratesToBattle01Start() throws {
        let (_, defaults, suiteName) = makeProgressStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let unsupported = makeSnapshot(.script04ConversationVoiceCompleted)
        let encoded = try JSONEncoder().encode(unsupported).base64EncodedString()
        defaults.set(encoded, forKey: TuringStoryProgressStore.Key.snapshot)

        let reloaded = TuringStoryProgressStore(defaults: defaults)

        XCTAssertEqual(reloaded.snapshot?.checkpoint, .script03PromptVoiceCompleted)
        XCTAssertTrue(reloaded.canContinue)
        let persisted = try XCTUnwrap(
            defaults.string(forKey: TuringStoryProgressStore.Key.snapshot)
        )
        let persistedData = try XCTUnwrap(Data(base64Encoded: persisted))
        let migrated = try JSONDecoder().decode(
            TuringEpisodeContinuationSnapshot.self,
            from: persistedData
        )
        XCTAssertEqual(migrated.checkpoint, .script03PromptVoiceCompleted)
    }

    func testProgressIgnoresDuplicateAndRegressiveEvents() throws {
        let (store, defaults, suiteName) = makeProgressStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstEvent = UUID()

        let first = try store.commit(
            episodeID: .prologue,
            checkpoint: .script01PromptVoiceCompleted,
            sourceEventID: firstEvent,
            contentRevision: TuringStoryProgressStore.prologueContentRevision
        )
        let duplicate = try store.commit(
            episodeID: .prologue,
            checkpoint: .script01PromptVoiceCompleted,
            sourceEventID: firstEvent,
            contentRevision: TuringStoryProgressStore.prologueContentRevision
        )
        let latest = try store.commit(
            episodeID: .prologue,
            checkpoint: .script02PromptVoiceCompleted,
            sourceEventID: UUID(),
            contentRevision: TuringStoryProgressStore.prologueContentRevision
        )
        let regressive = try store.commit(
            episodeID: .prologue,
            checkpoint: .script01ConversationVoiceCompleted,
            sourceEventID: UUID(),
            contentRevision: TuringStoryProgressStore.prologueContentRevision
        )

        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(latest.checkpoint, .script02PromptVoiceCompleted)
        XCTAssertEqual(regressive, latest)
        XCTAssertEqual(store.snapshot?.revision, 2)
    }

    func testSnapshotContainsOnlyLogicalContinuationFields() throws {
        let snapshot = makeSnapshot(.script03PromptVoiceCompleted)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "schemaVersion", "episodeID", "checkpoint", "revision",
                "committedAt", "sourceEventID", "contentRevision"
            ]
        )
        for forbidden in [
            "room", "transform", "entity", "audio", "task", "prompt",
            "generated", "model", "walkie", "battle"
        ] {
            XCTAssertFalse(object.keys.contains { $0.localizedCaseInsensitiveContains(forbidden) })
        }
    }

    func testDestinationPlannerRestoresExactAuthoredActions() throws {
        let checkpointOne = try TuringStoryDestinationPlanner.destination(
            for: makeSnapshot(.script01PromptVoiceCompleted)
        )
        XCTAssertEqual(checkpointOne.completedScriptPointIDs, ["prologue.scriptPoint01"])
        XCTAssertEqual(checkpointOne.walkieAction, .microphone)
        XCTAssertEqual(checkpointOne.pendingConversationAdvance?.nextScriptPointID, "prologue.scriptPoint02")
        XCTAssertEqual(checkpointOne.battleState, .absent)

        let checkpointTwo = try TuringStoryDestinationPlanner.destination(
            for: makeSnapshot(.script01ConversationVoiceCompleted)
        )
        XCTAssertEqual(
            checkpointTwo.walkieAction,
            .play(
                scriptPointID: "prologue.scriptPoint02",
                trigger: .continuationRestore(checkpoint: .script01ConversationVoiceCompleted)
            )
        )

        let checkpointThree = try TuringStoryDestinationPlanner.destination(
            for: makeSnapshot(.script02PromptVoiceCompleted)
        )
        XCTAssertEqual(
            checkpointThree.walkieAction,
            .play(
                scriptPointID: "prologue.scriptPoint03",
                trigger: .continuationRestore(checkpoint: .script02PromptVoiceCompleted)
            )
        )

        let checkpointFour = try TuringStoryDestinationPlanner.destination(
            for: makeSnapshot(.script03PromptVoiceCompleted)
        )
        XCTAssertEqual(checkpointFour.walkieAction, .microphone)
        XCTAssertEqual(checkpointFour.battleState, .battle01Start)
        XCTAssertEqual(checkpointFour.mediaState, .battle01)
    }

    func testMicrophoneContinuationRestoresLatestAuthoredPRContext() throws {
        XCTAssertEqual(
            TuringStoryStateTeleportCoordinator.conversationContextScriptPointID(
                for: .script01PromptVoiceCompleted
            ),
            "prologue.scriptPoint01"
        )
        XCTAssertEqual(
            TuringStoryStateTeleportCoordinator.conversationContextScriptPointID(
                for: .script03PromptVoiceCompleted
            ),
            "prologue.scriptPoint03"
        )
        XCTAssertNil(
            TuringStoryStateTeleportCoordinator.conversationContextScriptPointID(
                for: .script01ConversationVoiceCompleted
            )
        )
        XCTAssertNil(
            TuringStoryStateTeleportCoordinator.conversationContextScriptPointID(
                for: .script02PromptVoiceCompleted
            )
        )

        let flow = try TuringFlowDescriptorStore().require(
            "prologue.scriptPoint03"
        )
        let prerecording = try TuringPrerecordingStore().descriptor(
            id: flow.transmission.prerecordingID
        )

        XCTAssertEqual(
            prerecording.prerecordingID,
            "prologue.walkie.bigMike.scriptPoint03.001"
        )
        XCTAssertEqual(prerecording.transcriptMode, .manual)
        XCTAssertFalse(
            prerecording.transcript.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        )
    }

    func testNewPrologueUsesSparseInitialState() throws {
        let destination = try TuringStoryDestinationPlanner.startOfEpisode(.prologue)
        XCTAssertEqual(destination.completedScriptPointIDs, [])
        XCTAssertEqual(
            destination.walkieAction,
            .play(scriptPointID: "prologue.scriptPoint01", trigger: .userPlay)
        )
        XCTAssertEqual(destination.doorState, .closed)
        XCTAssertEqual(destination.battleState, .absent)
        XCTAssertEqual(destination.mediaState, .silent)
    }

    func testStagePreparationIsSingleGenerationUntilInvalidated() {
        let stage = TuringStoryStageCoordinator()
        let first = stage.beginPreparation(reason: "test.first")
        let joined = stage.beginPreparation(reason: "test.duplicate")
        XCTAssertEqual(first, joined)
        XCTAssertEqual(stage.state, .preparing(generation: first))

        stage.markEstablished(generation: first)
        XCTAssertTrue(stage.isEstablished)
        XCTAssertEqual(stage.beginPreparation(reason: "test.established"), first)

        stage.invalidate(reason: "test.shutdown")
        let second = stage.beginPreparation(reason: "test.nextSession")
        XCTAssertGreaterThan(second, first)
    }

    func testLayoutFingerprintDetectsAnyPropWallOrOccupancyChange() {
        let wall = UUID()
        let occupancy = UUID()
        let baseline = fingerprint(wall: wall, occupancy: occupancy)
        XCTAssertEqual(baseline, fingerprint(wall: wall, occupancy: occupancy))

        var moved = matrix_identity_float4x4
        moved.columns.3.x = 0.01
        let movedDoor = TuringStoryEstablishedLayoutFingerprint(
            doorWorldTransform: moved,
            windowWorldTransform: matrix_identity_float4x4,
            walkieShelfWorldTransform: matrix_identity_float4x4,
            rollingBenchWorldTransform: matrix_identity_float4x4,
            posterWorldTransform: matrix_identity_float4x4,
            canonicalWallIDs: [wall],
            occupancyIDs: [occupancy]
        )
        XCTAssertNotEqual(baseline, movedDoor)
        XCTAssertNotEqual(baseline, fingerprint(wall: UUID(), occupancy: occupancy))
        XCTAssertNotEqual(baseline, fingerprint(wall: wall, occupancy: UUID()))
    }

    func testProductionPickerAndTeleportContainNoRescanOrPlacementReset() throws {
        let picker = try appSource("Turing/Story/TuringStoryEpisodePickerView.swift")
        let teleport = try appSource("Turing/Story/TuringStoryStateTeleportCoordinator.swift")
        let forbidden = [
            "requestTuringStoryPlacementRoomScan", "beginRequest", "waitUntilReady",
            "roomSkinningCoordinator.reset", "wallLayoutCoordinator.reset",
            "doorBundleController.reset", "windowBundleController.reset",
            "rollingBenchBundleController.reset", "walkieBundleController.reset"
        ]
        for token in forbidden {
            XCTAssertFalse(picker.contains(token), "Picker contains forbidden token: \(token)")
            XCTAssertFalse(teleport.contains(token), "Teleport contains forbidden token: \(token)")
        }
        XCTAssertTrue(picker.contains("TuringStoryStateTeleportCoordinator.shared.apply"))
    }

    func testContinuationStateDoesNotEnterFoundationPromptTemplates() throws {
        let forbidden = [
            "checkpoint", "completedScriptPoint", "continuation snapshot",
            "room placement", "Battle01 state", "walkie state"
        ]
        for path in [
            "../TuringResources/Turing/Prompts/voicePrompt_characterIntent.txt",
            "../TuringResources/Turing/Prompts/conversationPrompt_playerTurn_noBible.txt"
        ] {
            let prompt = try appSource(path)
            for token in forbidden {
                XCTAssertFalse(
                    prompt.localizedCaseInsensitiveContains(token),
                    "Prompt \(path) contains continuation state: \(token)"
                )
            }
        }
    }

    private func makeProgressStore() -> (
        TuringStoryProgressStore,
        UserDefaults,
        String
    ) {
        let suiteName = "TuringStoryProgressStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (TuringStoryProgressStore(defaults: defaults), defaults, suiteName)
    }

    private func makeSnapshot(
        _ checkpoint: TuringPrologueCheckpoint
    ) -> TuringEpisodeContinuationSnapshot {
        TuringEpisodeContinuationSnapshot(
            schemaVersion: TuringEpisodeContinuationSnapshot.currentSchemaVersion,
            episodeID: .prologue,
            checkpoint: checkpoint,
            revision: 1,
            committedAt: Date(timeIntervalSince1970: 1),
            sourceEventID: UUID(),
            contentRevision: TuringStoryProgressStore.prologueContentRevision
        )
    }

    private func fingerprint(
        wall: UUID,
        occupancy: UUID
    ) -> TuringStoryEstablishedLayoutFingerprint {
        TuringStoryEstablishedLayoutFingerprint(
            doorWorldTransform: matrix_identity_float4x4,
            windowWorldTransform: matrix_identity_float4x4,
            walkieShelfWorldTransform: matrix_identity_float4x4,
            rollingBenchWorldTransform: matrix_identity_float4x4,
            posterWorldTransform: matrix_identity_float4x4,
            canonicalWallIDs: [wall],
            occupancyIDs: [occupancy]
        )
    }

    private func appSource(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let productRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = productRoot
            .appendingPathComponent("Gravitas Plague")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
