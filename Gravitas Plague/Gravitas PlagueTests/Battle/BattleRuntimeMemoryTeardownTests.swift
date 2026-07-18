import Foundation
import XCTest

@testable import Gravitas_Plague

final class BattleRuntimeMemoryTeardownTests: XCTestCase {
    func testReleaseReportRequiresControllerDeallocationProof() {
        let result = releaseResult(weakControllerReleased: false)
        let report = releaseReport(enemyResults: [result])

        XCTAssertTrue(report.allHeavyEnemyRuntimesReleased)
        XCTAssertFalse(report.allEnemyControllersReleased)
    }

    func testReleaseReportAcceptsReleasedRuntimeAndController() {
        let result = releaseResult(weakControllerReleased: true)
        let report = releaseReport(enemyResults: [result])

        XCTAssertTrue(report.allHeavyEnemyRuntimesReleased)
        XCTAssertTrue(report.allEnemyControllersReleased)
        XCTAssertTrue(report.fullPortalReleased)
        XCTAssertTrue(report.musicStillPlaying)
    }

    func testBattleCompletionArmsNextActionOnlyAfterRuntimeRelease() throws {
        let source = try appSource(
            "Battle/Battle01/Battle01Coordinator.swift"
        )
        let cleanup = try XCTUnwrap(
            source.range(of: "runtimeCleanup.releaseBattle(")
        )
        let event = try XCTUnwrap(
            source.range(of: "BattleRuntimeReleasedEvent(")
        )
        let nextAction = try XCTUnwrap(
            source.range(of: "self.onPostBattleHold(event)")
        )

        XCTAssertLessThan(cleanup.lowerBound, event.lowerBound)
        XCTAssertLessThan(event.lowerBound, nextAction.lowerBound)
        XCTAssertFalse(source.contains("forceCleanupFromHordeScene"))
    }

    func testDoorClosesWithCompletionOwnedSFXBeforeExteriorRelease() throws {
        let door = try appSource(
            "Turing/Props/TuringStoryDoorBundleController.swift"
        )
        let animation = try appSource(
            "Turing/Props/TuringStoryDoorAnimationController.swift"
        )
        let battleCloseStart = try XCTUnwrap(
            door.range(of: "func closeForBattleAndUnloadPortal(")
        )
        let battleCloseSource = door[battleCloseStart.lowerBound...]
        let closeWait = try XCTUnwrap(
            battleCloseSource.range(
                of: "try await animationController.closeAndWait("
            )
        )
        let releaseCheck = try XCTUnwrap(
            battleCloseSource.range(
                of: "battlePortalFullExteriorResident == false"
            )
        )

        XCTAssertLessThan(closeWait.lowerBound, releaseCheck.lowerBound)
        XCTAssertTrue(animation.contains("pendingCloseSFXIDs"))
        XCTAssertTrue(animation.contains("closeSFXActualCompletion: true"))
        XCTAssertTrue(animation.contains("controller.completionHandler"))
    }

    func testPortalUnloadDropsAuthoredExteriorEntityReferences() throws {
        let source = try appSource(
            "Turing/Props/TuringStoryDoorBundleController.swift"
        )

        XCTAssertTrue(source.contains("record.source = nil"))
        XCTAssertTrue(source.contains("portalWorldRoot.children.removeAll()"))
        XCTAssertTrue(source.contains("rehydratePortalOnlyEntitiesIfNeeded"))
    }

    func testAftermathOwnerHasNoBattleOrEnemyReference() throws {
        let source = try appSource(
            "Story/Audio/StoryAftermathMusicActor.swift"
        )

        XCTAssertFalse(source.contains("Battle01Coordinator"))
        XCTAssertFalse(source.contains("JockRetargetTestController"))
        XCTAssertFalse(source.contains("TuringStoryDoor"))
        XCTAssertTrue(source.contains("AVQueuePlayer"))
        XCTAssertTrue(source.contains("AVPlayerLooper"))
    }

    private func releaseResult(
        weakControllerReleased: Bool
    ) -> BattleEnemyRuntimeReleaseResult {
        BattleEnemyRuntimeReleaseResult(
            identity: BattleEnemyRuntimeIdentity(
                battleInstanceID: UUID(),
                enemyID: UUID(),
                enemyTypeID: "grandma"
            ),
            heavyRuntimeReleased: true,
            visibleRuntimeRemoved: true,
            staticCorpseInstalled: false,
            releasedPreparedClipCount: 12,
            releasedCollisionCount: 1,
            releasedAudioControllerCount: 1,
            weakControllerReleased: weakControllerReleased,
            notes: []
        )
    }

    private func releaseReport(
        enemyResults: [BattleEnemyRuntimeReleaseResult]
    ) -> BattleRuntimeReleaseReport {
        let snapshot = BattleRuntimeMemorySnapshot(
            label: "test",
            physicalFootprintMB: 1,
            residentSizeMB: 1,
            availableProcessMemoryMB: 1
        )
        return BattleRuntimeReleaseReport(
            battleInstanceID: UUID(),
            enemyResults: enemyResults,
            fullPortalReleased: true,
            musicStillPlaying: true,
            before: snapshot,
            after: snapshot
        )
    }

    private func appSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: try appSourceURL(relativePath),
            encoding: .utf8
        )
    }

    private func appSourceURL(_ relativePath: String) throws -> URL {
        let productRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return productRoot
            .appendingPathComponent("Gravitas Plague")
            .appendingPathComponent(relativePath)
    }
}
