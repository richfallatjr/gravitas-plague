import Foundation
import XCTest

@testable import Gravitas_Plague

@MainActor
final class TuringDoorPortalLifecycleTests: XCTestCase {
    func testStoryDomeUsesAuthoredOffsetAndSingleSidedInterior() throws {
        XCTAssertEqual(
            PortalHDRIDomePlacementTuning.storyOpeningRadiusMeters,
            12.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PortalHDRIDomePlacementTuning.storyOpeningCenterOffsetZ,
            -9.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PortalHDRIDomePlacementTuning.storyOpeningCameraClearanceMeters,
            3.0,
            accuracy: 0.0001
        )

        let source = try appSource(
            "RoomSkinning/EnvironmentSpherePortalContentProvider.swift"
        )
        XCTAssertTrue(source.contains("material.faceCulling = .back"))
        XCTAssertFalse(source.contains("material.faceCulling = .none"))
    }

    func testManualDoorLifecycleHidesInteractionDuringTransitions() {
        let lifecycle = TuringStoryDoorPortalLifecycleController()

        XCTAssertEqual(lifecycle.state, .closedUnloaded)
        XCTAssertEqual(lifecycle.presentation, .open)

        let claim = lifecycle.beginPlayerOpen()
        XCTAssertNotNil(claim)
        XCTAssertEqual(lifecycle.presentation, .hidden)

        guard let claim else { return }
        lifecycle.markClosedReady(lease: claim.lease)
        XCTAssertEqual(lifecycle.presentation, .hidden)
        lifecycle.markOpening(lease: claim.lease)
        XCTAssertEqual(lifecycle.presentation, .hidden)
        lifecycle.markOpen(lease: claim.lease)
        XCTAssertEqual(lifecycle.presentation, .close)
        lifecycle.markClosing(lease: claim.lease)
        XCTAssertEqual(lifecycle.presentation, .hidden)
        lifecycle.markUnloading(requestID: UUID(), lease: claim.lease)
        XCTAssertEqual(lifecycle.presentation, .hidden)
        lifecycle.finishUnloaded(lease: claim.lease)
        XCTAssertEqual(lifecycle.presentation, .open)
    }

    func testBattleOwnershipAllowsOpenUntilDoorTransitionStarts() {
        let lifecycle = TuringStoryDoorPortalLifecycleController()
        let battleID = UUID()
        let lease = lifecycle.acquireForBattle(
            battleInstanceID: battleID,
            fullExteriorLoaded: false,
            doorState: .closed
        )

        XCTAssertEqual(lease.owner, .battle(battleID))
        XCTAssertTrue(lifecycle.isBattleOwned)
        XCTAssertEqual(lifecycle.presentation, .open)

        lifecycle.markClosedReady(lease: lease)
        XCTAssertEqual(lifecycle.presentation, .open)
        lifecycle.markOpening(lease: lease)
        XCTAssertEqual(lifecycle.presentation, .hidden)
        lifecycle.markOpen(lease: lease)
        XCTAssertEqual(lifecycle.presentation, .hidden)
    }

    func testBattleDoorTapReusesBattlePortalInsteadOfClaimingManualDoor() throws {
        let source = try appSource(
            "Turing/Props/TuringStoryDoorBundleController.swift"
        )
        let start = try XCTUnwrap(
            source.range(of: "private func requestBattleDoorOpen(")
        )
        let remainder = source[start.lowerBound...]
        let end = try XCTUnwrap(
            remainder.range(of: "private func requestPlayerDoorClose(")
        )
        let battleOpenSource = remainder[..<end.lowerBound]

        XCTAssertNotNil(battleOpenSource.range(of: "acquireBattlePortal("))
        XCTAssertNotNil(battleOpenSource.range(of: "openForBattle("))
        XCTAssertNil(battleOpenSource.range(of: "claimManualDoor("))
    }

    func testBattleEnemyReleasesBeforeDoorClose() throws {
        let source = try appSource(
            "Battle/Battle01/Battle01Coordinator.swift"
        )
        let cleanupStart = try XCTUnwrap(
            source.range(of: "private func scheduleRuntimeCleanup(")
        )
        let cleanupSource = source[cleanupStart.lowerBound...]
        let enemyRelease = try XCTUnwrap(
            cleanupSource.range(of: "runtimeCleanup.releaseEnemy(")
        )
        let doorClose = try XCTUnwrap(
            cleanupSource.range(of: "door.closeForBattleAndUnloadPortal(")
        )

        XCTAssertLessThan(enemyRelease.lowerBound, doorClose.lowerBound)
        XCTAssertNil(
            cleanupSource.prefix(upTo: doorClose.lowerBound)
                .range(of: "clock.sleep")
        )
    }

    func testManualOpenLoadsBeforeAnimationAndCloseUnloadsAfterCompletion() throws {
        let source = try appSource(
            "Turing/Props/TuringStoryDoorBundleController.swift"
        )
        let openStart = try XCTUnwrap(
            source.range(of: "private func requestDoorOpen(")
        )
        let openSource = source[openStart.lowerBound...]
        let load = try XCTUnwrap(
            openSource.range(of: "ensurePortalWorldLoaded(")
        )
        let open = try XCTUnwrap(
            openSource.range(of: "openAndWait(")
        )
        XCTAssertLessThan(load.lowerBound, open.lowerBound)

        let closeStart = try XCTUnwrap(
            source.range(of: "private func closeDoorAndUnload(")
        )
        let closeSource = source[closeStart.lowerBound...]
        let close = try XCTUnwrap(
            closeSource.range(of: "closeAndWait(")
        )
        let unload = try XCTUnwrap(
            closeSource.range(of: "unloadPortalWorld(")
        )
        XCTAssertLessThan(close.lowerBound, unload.lowerBound)
    }

    func testTuringPreflightRunsBeforeFreshPoolAcquisition() throws {
        let source = try appSource(
            "Turing/Flow/TuringCharacterQwenRenderSession.swift"
        )
        let preflight = try XCTUnwrap(
            source.range(of: "prepareForTuringHighMemoryRun(")
        )
        let poolAcquisition = try XCTUnwrap(
            source.range(of: "arbiter.acquire(owner:")
        )

        XCTAssertLessThan(preflight.lowerBound, poolAcquisition.lowerBound)
    }

    func testNoOpenDoorFallbackBackdropExists() throws {
        let productRoot = appProductRoot()
        let enumerator = FileManager.default.enumerator(
            at: productRoot,
            includingPropertiesForKeys: nil
        )
        var combined = ""
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            combined += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        XCTAssertFalse(combined.contains("MinimalPortalBackdrop"))
        XCTAssertFalse(combined.contains("blackBackdrop"))
        XCTAssertFalse(combined.contains("minimalOpenDoor"))
    }

    private func appSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: appProductRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func appProductRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Gravitas Plague")
    }
}
