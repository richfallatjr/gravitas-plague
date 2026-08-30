import Foundation
import simd
import XCTest

@testable import Gravitas_Plague

@MainActor
final class Chapter01RobotEncounterTests: XCTestCase {
    func testEveryChapter01RichToMikeSendUsesEstablishedCommsContract() throws {
        let store = TuringFlowDescriptorStore()
        let prologueRich = try store.require("prologue.scriptPoint02")
        let prologueMike = try store.require("prologue.scriptPoint03")

        let pairs = [
            (
                try store.require("chapter01.walkie.rich.script06"),
                try store.require("chapter01.walkie.bigMike.script07")
            ),
            (
                try store.require("chapter01.walkie.rich.script08"),
                try store.require("chapter01.walkie.bigMike.script09")
            )
        ]

        for (rich, mike) in pairs {
            XCTAssertEqual(
                rich.transmission.commSFX,
                prologueRich.transmission.commSFX,
                rich.scriptPointID
            )
            XCTAssertEqual(
                mike.transmission.fixedLeadInSeconds,
                prologueMike.transmission.fixedLeadInSeconds,
                mike.scriptPointID
            )
            XCTAssertEqual(
                mike.transmission.fixedLeadInSeconds,
                nil,
                mike.scriptPointID
            )
            XCTAssertEqual(
                mike.transmission.computeStart,
                .beforePrerecording,
                mike.scriptPointID
            )
        }
    }

    func testRobotAudioTeardownForceStopsEveryCleanupAttempt() async {
        let enemyID = UUID()
        var stoppedIDs: [UUID] = []
        var detachCount = 0
        let lease = Chapter01RobotAudioAttachmentLease(
            enemyID: enemyID,
            stopHostAudioSource: { stoppedIDs.append($0) },
            detachAudioEmitter: { detachCount += 1 }
        )

        await lease.deactivate(reason: "doorClosed")
        await lease.deactivate(reason: "cleanupFallback")

        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(stoppedIDs, [enemyID, enemyID])
        XCTAssertEqual(detachCount, 2)
    }

    func testAntigenRemainsHiddenOnRollingCart() {
        XCTAssertFalse(StoryItemRewardPresenter.displaysAntigenOnRollingCart)
    }

    func testDefinitionLocksRobotContract() throws {
        let definition = try Chapter01RobotDefinitionStore().load()
        XCTAssertEqual(definition.encounterID, "chapter01.encounter.gravitasRobot.001")
        XCTAssertEqual(definition.characterResource, "robot_biped.usdz")
        XCTAssertEqual(definition.animations.idle, "drone_idle_01")
        XCTAssertEqual(definition.animations.walk, "robot_walk_01")
        XCTAssertEqual(definition.approach.stopDistanceMeters, 1.5, accuracy: 0.0001)
        XCTAssertEqual(definition.scan.stableDurationSeconds, 5, accuracy: 0.0001)
        XCTAssertEqual(definition.combat.incomingPlayerHitAcceptanceProbability, 0.1, accuracy: 0.0001)
        XCTAssertEqual(definition.combat.acceptedPlayerHitsToDestroyMinimum, 30)
        XCTAssertEqual(definition.combat.acceptedPlayerHitsToDestroyMaximum, 40)
        XCTAssertEqual(definition.combat.confirmedRobotHitsToKillPlayer, 5)
        XCTAssertEqual(definition.reward.eventID, "chapter01.reward.antigenPack.001")
    }

    func testDroneScanIdleIsAStationaryLoopingRobotPose() throws {
        let manifest = try JockAnimationLibraryLoader.loadManifest()
        let summary = try XCTUnwrap(
            manifest.clips.first { $0.clipID == "drone_idle_01" }
        )
        let clip = try JockAnimationLibraryLoader.loadClip(summary: summary)

        XCTAssertTrue(summary.approvedForRuntime)
        XCTAssertTrue(clip.timing.looping)
        XCTAssertEqual(clip.timing.durationSeconds, 1, accuracy: 0.0001)
        XCTAssertEqual(clip.locomotion.enabled, false)
        XCTAssertEqual(clip.sourceRig?.characterID, "robot_biped")
        XCTAssertEqual(clip.joints.count, 24)
        XCTAssertEqual(clip.tracks.count, 48)
        XCTAssertEqual(Set(clip.tracks.map(\.joint)), Set(clip.joints))
    }

    func testSpeechCatalogHasSixUniqueAuthoredCues() throws {
        let catalog = try Chapter01RobotSpeechCatalog.load()
        XCTAssertEqual(catalog.cues.count, 6)
        XCTAssertEqual(Set(catalog.cues.map(\.cueID)), Set(Chapter01RobotSpeechCue.allCases))
        XCTAssertEqual(Set(catalog.cues.map(\.audioFile)).count, 6)
        for cue in catalog.cues {
            let url = try Chapter01RobotResourceResolver.requirePrerecording(cue.audioFile)
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
        }
    }

    func testChapterMusicCatalogUsesTheTwoAuthoredTracks() throws {
        let catalog = try Chapter01MusicCatalog.load()
        XCTAssertEqual(catalog.cues.count, 2)
        XCTAssertEqual(Set(catalog.cues.map(\.cueID)), Set(Chapter01MusicCue.allCases))
        XCTAssertEqual(
            catalog.descriptor(for: .dadWindow)?.resourcePath,
            "Turing/Audio/chapter01/dad-window-music.mp3"
        )
        XCTAssertEqual(
            catalog.descriptor(for: .robotAttack)?.resourcePath,
            "Turing/Audio/chapter01/robot-beserk-music.mp3"
        )
    }

    func testProductionAvailabilityAcceptsAuthoredRollingCartAntigen() throws {
        let availability = Chapter01RobotAvailability.evaluate()
        XCTAssertTrue(availability.isAvailable)
        XCTAssertTrue(availability.missingAuthoredResources.isEmpty)
        let descriptor = try Chapter01AntigenRewardDescriptor.load()
        XCTAssertEqual(descriptor.modelKind, .authoredBundleGroup)
        XCTAssertNil(descriptor.modelResourcePath)
        XCTAssertEqual(
            descriptor.rollingCartAnchorName,
            "antigen_anchor_root"
        )
        XCTAssertEqual(
            descriptor.authoredEntityNames,
            [
                "antigen_holster_root",
                "antigen_vile_01_root",
                "antigen_vile_02_root",
                "antigen_vile_03_root",
                "antigen_vile_04_root"
            ]
        )
    }

    func testHeadStillnessCompletesAfterContinuousFiveSeconds() async {
        let detector = HeadStillnessDetector(
            configuration: .init(
                requiredStableSeconds: 5,
                translationToleranceMeters: 0.05,
                rotationToleranceRadians: 8 * .pi / 180,
                trackingLossGraceSeconds: 0.35
            )
        )
        let transform = matrix_identity_float4x4
        let baseline = await detector.ingest(
            .init(timestampSeconds: 0, transform: transform, isTracked: true)
        )
        let completed = await detector.ingest(
            .init(timestampSeconds: 5, transform: transform, isTracked: true)
        )
        XCTAssertEqual(baseline, .baselineEstablished)
        XCTAssertEqual(completed, .completed)
    }

    func testMovementResetsAndTrackingLossNeverPunishes() async {
        let detector = HeadStillnessDetector(
            configuration: .init(
                requiredStableSeconds: 5,
                translationToleranceMeters: 0.05,
                rotationToleranceRadians: 8 * .pi / 180,
                trackingLossGraceSeconds: 0.35
            )
        )
        var moved = matrix_identity_float4x4
        moved.columns.3.x = 0.051
        _ = await detector.ingest(.init(timestampSeconds: 0, transform: matrix_identity_float4x4, isTracked: true))
        let paused = await detector.ingest(
            .init(timestampSeconds: 1, transform: nil, isTracked: false)
        )
        let resumed = await detector.ingest(
            .init(timestampSeconds: 2, transform: moved, isTracked: true)
        )
        XCTAssertEqual(paused, .trackingPaused)
        XCTAssertEqual(resumed, .trackingResumed)
        var movedAgain = moved
        movedAgain.columns.3.x += 0.051
        let movement = await detector.ingest(
            .init(timestampSeconds: 3, transform: movedAgain, isTracked: true)
        )
        let completed = await detector.ingest(
            .init(timestampSeconds: 8, transform: movedAgain, isTracked: true)
        )
        XCTAssertEqual(movement, .movement)
        XCTAssertEqual(completed, .completed)
    }

    @MainActor
    func testPlayerDiesOnFifthConfirmedRobotContact() {
        let budget = StoryPlayerHitBudget(maximumConfirmedHits: 5)
        for _ in 0..<4 {
            let terminal = budget.registerConfirmedHit()
            XCTAssertFalse(terminal)
        }
        let terminal = budget.registerConfirmedHit()
        XCTAssertTrue(terminal)
        let snapshot = budget.snapshot()
        XCTAssertEqual(snapshot.confirmedHits, 5)
        XCTAssertTrue(snapshot.terminal)
    }

    func testApproachTargetUsesPlayerForward() {
        let target = Chapter01RobotApproachController.desiredTarget(
            headPosition: SIMD3<Float>(0, 1.7, 0),
            headForward: SIMD3<Float>(0, 0, -1),
            floorY: 0,
            stopDistanceMeters: 1.5
        )
        XCTAssertEqual(target, SIMD3<Float>(0, 0, -1.5))
    }

    func testApproachTargetClampsInsideMappedFloor() {
        let floor = FloorCandidate(
            id: UUID(),
            anchorID: UUID(),
            worldTransform: matrix_identity_float4x4,
            center: .zero,
            normal: SIMD3<Float>(0, 1, 0),
            right: SIMD3<Float>(1, 0, 0),
            forward: SIMD3<Float>(0, 0, -1),
            width: 2,
            depth: 2,
            semantic: .floor,
            stabilityScore: 1,
            lastUpdated: Date()
        )
        let clamped = Chapter01RobotApproachController.clampToMappedFloor(
            SIMD3<Float>(4, 0, -4),
            floors: [floor]
        )
        XCTAssertEqual(clamped.x, 0.88, accuracy: 0.0001)
        XCTAssertEqual(clamped.z, -0.88, accuracy: 0.0001)
    }

    func testAntigenRewardIsExactlyOnceAcrossBothBranches() async throws {
        let suite = "Chapter01RobotEncounterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inventory = StoryInventoryStore(defaults: defaults)
        let transaction = StoryRewardTransaction(inventory: inventory)

        let first = try await transaction.grant(
            .init(
                eventID: "chapter01.reward.antigenPack.001",
                itemID: "antigen_pack",
                quantity: 1,
                source: .scanSuccess,
                sourceRuntimeID: UUID()
            )
        )
        let second = try await transaction.grant(
            .init(
                eventID: "chapter01.reward.antigenPack.001",
                itemID: "antigen_pack",
                quantity: 1,
                source: .robotKilled,
                sourceRuntimeID: UUID()
            )
        )

        XCTAssertTrue(first.wasNewlyGranted)
        XCTAssertFalse(second.wasNewlyGranted)
        XCTAssertEqual(second.totalQuantity, 1)
    }

    func testChapterProgressPersistsOnlyStableMonotonicCheckpoints() async throws {
        let suite = "Chapter01ProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Chapter01ProgressStore(defaults: defaults)

        _ = try await store.commit(.robotEncounterPending, sourceEventID: UUID())
        _ = try await store.commit(.antigenGranted, sourceEventID: UUID())
        _ = try await store.commit(.robotEncounterPending, sourceEventID: UUID())
        let snapshot = await store.currentSnapshot()

        XCTAssertEqual(snapshot?.checkpoint, .antigenGranted)
        XCTAssertEqual(snapshot?.revision, 2)
    }
}

@MainActor
final class Chapter01RobotInteractionTransferTests: XCTestCase {
    func testStoryTransitionBattleHamTransferHasNoOwnerGap() async throws {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.microphone, reason: "test")
        let turing = try await arbiter.claimManualTuring(runID: "script07", source: "test")
        let transitionID = UUID()
        let transition = try await arbiter.transferTuringToStoryTransition(
            turingLease: turing,
            transitionID: transitionID,
            reason: "dadWindow"
        )
        let battleID = UUID()
        let battle = try await arbiter.transferStoryTransitionToBattle(
            storyTransitionLease: transition,
            battleInstanceID: battleID,
            reason: "dadExitWalkStarted"
        )
        var snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.exclusiveOwner, .battle(battleInstanceID: battleID))
        XCTAssertTrue(snapshot.capabilities.isEmpty)

        let rolledBack = try await arbiter.transferBattleToStoryTransition(
            battleLease: battle,
            transitionID: transitionID,
            reason: "synchronousStartFailure"
        )
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.exclusiveOwner, rolledBack.owner)

        let retriedBattle = try await arbiter.transferStoryTransitionToBattle(
            storyTransitionLease: rolledBack,
            battleInstanceID: battleID,
            reason: "retry"
        )

        await arbiter.updateDoorState(.closedUnloaded, reason: "robotReleased")
        let ham = try await arbiter.transferBattleToTuring(
            battleLease: retriedBattle,
            runID: "chapter01.hamScript04",
            surfaceID: .hamReceiver,
            reason: "releaseBoundaryPassed"
        )
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.exclusiveOwner, ham.owner)
        XCTAssertTrue(snapshot.capabilities.isEmpty)
    }
}
