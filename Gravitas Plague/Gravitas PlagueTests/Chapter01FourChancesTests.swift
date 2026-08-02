import Foundation
import XCTest
@testable import Gravitas_Plague

@MainActor
final class Chapter01FourChancesTests: XCTestCase {
    func testBranchesUnlockSequentiallyAndCommitReadyCheckpoint() async throws {
        let suite = "Chapter01FourChancesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Chapter01ProgressStore(defaults: defaults)
        _ = try await store.commit(.antigenGranted, sourceEventID: UUID())
        _ = try await store.unlockPostRobotHub(sourceEventID: UUID())

        let current = await store.currentSnapshot()
        let initial = try XCTUnwrap(current)
        XCTAssertEqual(initial.postRobot.state(for: .dadFrame), .play)
        XCTAssertEqual(initial.postRobot.state(for: .walkie), .closed)
        XCTAssertEqual(initial.postRobot.state(for: .hamReceiver), .closed)

        let first = try await store.completePostRobotBranch(
            .dadFrame,
            terminalScriptPointID: Chapter01PostRobotBranch.dadFrame.terminalScriptPointID,
            sourceEventID: UUID()
        )
        XCTAssertEqual(first.snapshot.checkpoint, .postRobotHub)
        XCTAssertFalse(first.becameAllBranchesComplete)
        XCTAssertEqual(first.snapshot.postRobot.state(for: .dadFrame), .microphone)
        XCTAssertEqual(first.snapshot.postRobot.state(for: .walkie), .play)
        XCTAssertEqual(first.snapshot.postRobot.state(for: .hamReceiver), .closed)

        let second = try await store.completePostRobotBranch(
            .walkie,
            terminalScriptPointID: Chapter01PostRobotBranch.walkie.terminalScriptPointID,
            sourceEventID: UUID()
        )
        XCTAssertEqual(second.snapshot.postRobot.state(for: .dadFrame), .microphone)
        XCTAssertEqual(second.snapshot.postRobot.state(for: .walkie), .microphone)
        XCTAssertEqual(second.snapshot.postRobot.state(for: .hamReceiver), .play)

        let final = try await store.completePostRobotBranch(
            .hamReceiver,
            terminalScriptPointID: Chapter01PostRobotBranch.hamReceiver.terminalScriptPointID,
            sourceEventID: UUID()
        )
        XCTAssertTrue(final.becameAllBranchesComplete)
        XCTAssertTrue(final.snapshot.postRobot.allBranchesComplete)
        XCTAssertEqual(final.snapshot.checkpoint, .preDadFinalBattleReady)
        XCTAssertEqual(final.snapshot.postRobot.state(for: .dadFrame), .microphone)
        XCTAssertEqual(final.snapshot.postRobot.state(for: .walkie), .microphone)
        XCTAssertEqual(final.snapshot.postRobot.state(for: .hamReceiver), .microphone)
    }

    func testWalkieCannotCompleteBeforeDad() async throws {
        let suite = "Chapter01FourChancesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Chapter01ProgressStore(defaults: defaults)
        _ = try await store.unlockPostRobotHub(sourceEventID: UUID())

        do {
            _ = try await store.completePostRobotBranch(
                .walkie,
                terminalScriptPointID: Chapter01PostRobotBranch.walkie.terminalScriptPointID,
                sourceEventID: UUID()
            )
            XCTFail("Walkie completed before Dad.")
        } catch Chapter01Error.postRobotBranchNotAvailable(let branch) {
            XCTAssertEqual(branch, .walkie)
        }
    }

    func testDuplicateBranchCompletionIsIdempotent() async throws {
        let suite = "Chapter01FourChancesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Chapter01ProgressStore(defaults: defaults)
        _ = try await store.unlockPostRobotHub(sourceEventID: UUID())
        let eventID = UUID()
        let first = try await store.completePostRobotBranch(
            .dadFrame,
            terminalScriptPointID: Chapter01PostRobotBranch.dadFrame.terminalScriptPointID,
            sourceEventID: eventID
        )
        let duplicate = try await store.completePostRobotBranch(
            .dadFrame,
            terminalScriptPointID: Chapter01PostRobotBranch.dadFrame.terminalScriptPointID,
            sourceEventID: eventID
        )
        XCTAssertTrue(first.wasNewlyCompleted)
        XCTAssertFalse(duplicate.wasNewlyCompleted)
        XCTAssertEqual(first.snapshot.revision, duplicate.snapshot.revision)
    }

    func testAllFiveDescriptorsUseFoundationBeforePrerecording() throws {
        let ids = [
            "chapter01.dadFrame.rich.fourChances.001",
            "chapter01.walkie.rich.script08",
            "chapter01.walkie.bigMike.script09",
            "chapter01.hamReceiver.rich.script04",
            "chapter01.hamReceiver.cateye81.script05"
        ]
        for id in ids {
            let descriptor = try TuringFlowDescriptorStore().require(id)
            XCTAssertEqual(
                descriptor.transmission.computeStart,
                .foundationBeforePrerecording,
                id
            )
        }
    }

    func testChapterConversationKeysAreIsolatedFromPrologue() {
        XCTAssertNotEqual(
            TuringStorySurfaceFlowBinding.chapter01FourChancesDad.conversationKey,
            TuringStorySurfaceFlowBinding.prologueDadPhoto.conversationKey
        )
        XCTAssertNotEqual(
            TuringStorySurfaceFlowBinding.chapter01FourChancesWalkie.conversationKey,
            TuringStorySurfaceFlowBinding.prologueWalkie.conversationKey
        )
        XCTAssertNotEqual(
            TuringStorySurfaceFlowBinding.chapter01FourChancesHam.conversationKey,
            TuringStorySurfaceFlowBinding.prologueHamReceiver.conversationKey
        )
    }

    func testPostRobotSafetyIncludesExternalAudio() {
        let unsafe = makeReleaseReport(audioActive: true, sourceCount: 1)
        let safe = makeReleaseReport(audioActive: false, sourceCount: 0)
        XCTAssertFalse(unsafe.isSafeForPostRobotHub)
        XCTAssertTrue(safe.isSafeForPostRobotHub)
    }

    func testBrokenPostRobotRecordRepairsToTheSingleHubDestination() throws {
        let broken = Chapter01ProgressSnapshot(
            schemaVersion: Chapter01ProgressSnapshot.currentSchemaVersion,
            checkpoint: .postRobotHub,
            postRobot: .locked,
            revision: 4,
            sourceEventIDs: [UUID()],
            committedAt: Date(timeIntervalSince1970: 1),
            contentRevision: Chapter01ProgressStore.contentRevision
        )
        let data = try JSONEncoder().encode(broken)

        let repaired = try Chapter01ProgressStore.decodeAndMigrate(data)

        XCTAssertEqual(repaired.checkpoint, .postRobotHub)
        XCTAssertTrue(repaired.postRobot.unlocked)
        XCTAssertTrue(repaired.postRobot.completedBranches.isEmpty)
        XCTAssertEqual(repaired.revision, broken.revision + 1)
    }

    private func makeReleaseReport(
        audioActive: Bool,
        sourceCount: Int
    ) -> Chapter01RobotReleaseReport {
        Chapter01RobotReleaseReport(
            chapterRunID: UUID(),
            outcome: .rewardedRobotDeparted,
            dadRuntimeCount: 0,
            robotRuntimeCount: 0,
            preparedClipCount: 0,
            portalMirrorCount: 0,
            fullExteriorResident: false,
            doorState: .closedUnloaded,
            robotSpeechHandleCount: 0,
            robotCombatHandleCount: 0,
            activeEncounterTaskCount: 0,
            weakRobotControllerReleased: true,
            robotPresenceAudioActive: audioActive,
            robotExternalAudioSourceCount: sourceCount,
            physicalFootprintMB: 0,
            residentSizeMB: 0
        )
    }
}
