import XCTest

@testable import Gravitas_Plague

@MainActor
final class StoryInteractionArbiterTests: XCTestCase {
    func testPlayAndMicrophoneCapabilityMatrix() async {
        let arbiter = StoryInteractionArbiter()

        await arbiter.updateTuringGate(.play, reason: "test")
        var snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.walkiePresentation, .play)
        XCTAssertEqual(snapshot.doorPresentation, .open)
        XCTAssertEqual(snapshot.capabilities, [.walkiePlay, .doorOpen])

        await arbiter.updateTuringGate(.microphone, reason: "test")
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.walkiePresentation, .microphone)
        XCTAssertEqual(snapshot.doorPresentation, .open)
        XCTAssertEqual(snapshot.capabilities, [.walkieMicrophone, .doorOpen])

        await arbiter.updateTuringGate(.busy, reason: "test")
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.walkiePresentation, .hidden)
        XCTAssertEqual(snapshot.doorPresentation, .hidden)
        XCTAssertTrue(snapshot.capabilities.isEmpty)

        await arbiter.updateTuringGate(.closed, reason: "test")
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.walkiePresentation, .hidden)
        XCTAssertEqual(snapshot.doorPresentation, .open)
        XCTAssertEqual(snapshot.capabilities, [.doorOpen])
    }

    func testDoorIsAvailableBeforeAnyTuringFlowStarts() async throws {
        let arbiter = StoryInteractionArbiter()

        var snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.turingGate, .closed)
        XCTAssertEqual(snapshot.doorState, .closedUnloaded)
        XCTAssertEqual(snapshot.walkiePresentation, .hidden)
        XCTAssertEqual(snapshot.doorPresentation, .open)
        XCTAssertEqual(snapshot.capabilities, [.doorOpen])

        let lease = try await arbiter.claimManualDoor(
            source: "beforeGameStarts"
        )
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.exclusiveOwner, lease.owner)
        XCTAssertEqual(snapshot.doorPresentation, .hidden)
        XCTAssertTrue(snapshot.capabilities.isEmpty)
    }

    func testChapterContinueCanClaimFreshStoryTransition() async throws {
        let arbiter = StoryInteractionArbiter()
        let transitionID = UUID()

        let lease = try await arbiter.claimStoryTransition(
            transitionID: transitionID,
            source: "chapterContinueTest"
        )
        let snapshot = await arbiter.currentSnapshot()

        XCTAssertEqual(
            lease.owner,
            .storyTransition(transitionID: transitionID)
        )
        XCTAssertEqual(snapshot.exclusiveOwner, lease.owner)
        XCTAssertTrue(snapshot.capabilities.isEmpty)
        XCTAssertEqual(snapshot.walkiePresentation, .hidden)
        XCTAssertEqual(snapshot.doorPresentation, .hidden)
    }

    func testDoorClaimHidesWalkieBeforeLoadingAndRetainsCloseOnly() async throws {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.play, reason: "test")

        let lease = try await arbiter.claimManualDoor(source: "test")
        var snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.exclusiveOwner, lease.owner)
        XCTAssertEqual(snapshot.walkiePresentation, .hidden)
        XCTAssertEqual(snapshot.doorPresentation, .hidden)
        XCTAssertTrue(snapshot.capabilities.isEmpty)

        await arbiter.updateDoorState(.open, reason: "test")
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.capabilities, [.doorClose])
        XCTAssertEqual(snapshot.walkiePresentation, .hidden)
        XCTAssertEqual(snapshot.doorPresentation, .close)

        await arbiter.updateDoorState(.closedUnloaded, reason: "test")
        await arbiter.release(lease, reason: "test")
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.capabilities, [.walkiePlay, .doorOpen])
    }

    func testDoorCannotEnterOpenStateWithoutExclusiveOwner() async {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.play, reason: "test")
        await arbiter.updateDoorState(.open, reason: "invalidTestTransition")

        let snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.doorState, .closedUnloaded)
        XCTAssertNil(snapshot.exclusiveOwner)
        XCTAssertEqual(snapshot.capabilities, [.walkiePlay, .doorOpen])
    }

    func testTuringAndDoorClaimsHaveExactlyOneWinner() async {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.play, reason: "test")

        let accepted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await arbiter.claimManualDoor(source: "race")) != nil
            }
            group.addTask {
                (try? await arbiter.claimManualTuring(
                    runID: "race",
                    source: "race"
                )) != nil
            }
            var count = 0
            for await didAccept in group where didAccept {
                count += 1
            }
            return count
        }

        XCTAssertEqual(accepted, 1)
        let snapshot = await arbiter.currentSnapshot()
        XCTAssertNotNil(snapshot.exclusiveOwner)
        XCTAssertTrue(snapshot.capabilities.isEmpty)
    }

    func testTuringClaimPreventsDoorClaim() async throws {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.play, reason: "test")
        _ = try await arbiter.claimManualTuring(runID: "run", source: "test")

        do {
            _ = try await arbiter.claimManualDoor(source: "test")
            XCTFail("Door claim should be rejected while Turing owns interaction.")
        } catch {
            XCTAssertEqual(error as? StoryInteractionClaimError, .exclusiveOwnerActive)
        }
    }

    func testDoorClaimPreventsTuringClaim() async throws {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.microphone, reason: "test")
        _ = try await arbiter.claimManualDoor(source: "test")

        do {
            _ = try await arbiter.claimManualTuring(runID: "run", source: "test")
            XCTFail("Turing claim should be rejected while the door owns interaction.")
        } catch {
            XCTAssertEqual(error as? StoryInteractionClaimError, .exclusiveOwnerActive)
        }
    }

    func testSecondDoorAndTuringClaimsAreRejected() async throws {
        let doorArbiter = StoryInteractionArbiter()
        await doorArbiter.updateTuringGate(.play, reason: "test")
        _ = try await doorArbiter.claimManualDoor(source: "first")
        await XCTAssertThrowsStoryInteractionError(.exclusiveOwnerActive) {
            _ = try await doorArbiter.claimManualDoor(source: "second")
        }

        let turingArbiter = StoryInteractionArbiter()
        await turingArbiter.updateTuringGate(.play, reason: "test")
        _ = try await turingArbiter.claimManualTuring(runID: "first", source: "first")
        await XCTAssertThrowsStoryInteractionError(.exclusiveOwnerActive) {
            _ = try await turingArbiter.claimManualTuring(runID: "second", source: "second")
        }
    }

    func testDoorToTuringTransferNeverPublishesNilOwner() async throws {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.microphone, reason: "test")
        let doorLease = try await arbiter.claimManualDoor(source: "test")
        await arbiter.updateDoorState(.closedUnloaded, reason: "test")

        let turingLease = try await arbiter.transferDoorToTuring(
            doorLease: doorLease,
            runID: "automatic",
            reason: "test"
        )
        let snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.exclusiveOwner, turingLease.owner)
        XCTAssertEqual(turingLease.owner, .turingFlow(runID: "automatic"))
        XCTAssertTrue(snapshot.capabilities.isEmpty)
    }

    func testTuringToBattleTransferAndReleaseRestoresGateActions() async throws {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.microphone, reason: "test")
        let turingLease = try await arbiter.claimManualTuring(
            runID: "script03",
            source: "test"
        )
        let battleID = UUID()
        let battleLease = try await arbiter.transferTuringToBattle(
            turingLease: turingLease,
            battleInstanceID: battleID,
            reason: "test"
        )
        let battleSnapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(
            battleSnapshot.exclusiveOwner,
            .battle(battleInstanceID: battleID)
        )
        XCTAssertTrue(battleSnapshot.capabilities.isEmpty)
        XCTAssertEqual(battleSnapshot.walkiePresentation, .hidden)
        XCTAssertEqual(battleSnapshot.doorPresentation, .hidden)

        await arbiter.updateDoorState(.loading, reason: "battlePortalLoad")
        var activeBattleSnapshot = await arbiter.currentSnapshot()
        XCTAssertTrue(activeBattleSnapshot.capabilities.isEmpty)
        XCTAssertEqual(activeBattleSnapshot.doorPresentation, .hidden)

        await arbiter.updateDoorState(.opening, reason: "battleDoorOpening")
        activeBattleSnapshot = await arbiter.currentSnapshot()
        XCTAssertTrue(activeBattleSnapshot.capabilities.isEmpty)
        XCTAssertEqual(activeBattleSnapshot.doorPresentation, .hidden)

        await arbiter.updateDoorState(.closedUnloaded, reason: "battleReset")

        await arbiter.release(battleLease, reason: "test")
        let snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.capabilities, [.walkieMicrophone, .doorOpen])
    }

    func testOwnershipTransfersNeverPublishNilOwnerGap() async throws {
        let arbiter = StoryInteractionArbiter()
        let stream = await arbiter.snapshots()
        var snapshots = stream.makeAsyncIterator()
        _ = await snapshots.next()

        await arbiter.updateTuringGate(.play, reason: "test")
        _ = await snapshots.next()

        let doorLease = try await arbiter.claimManualDoor(source: "test")
        let doorClaim = await snapshots.next()
        XCTAssertEqual(doorClaim?.exclusiveOwner, doorLease.owner)

        let turingLease = try await arbiter.transferDoorToTuring(
            doorLease: doorLease,
            runID: "flow",
            reason: "test"
        )
        let turingTransfer = await snapshots.next()
        XCTAssertEqual(turingTransfer?.exclusiveOwner, turingLease.owner)

        let battleID = UUID()
        let battleLease = try await arbiter.transferTuringToBattle(
            turingLease: turingLease,
            battleInstanceID: battleID,
            reason: "test"
        )
        let battleTransfer = await snapshots.next()
        XCTAssertEqual(battleTransfer?.exclusiveOwner, battleLease.owner)
        XCTAssertEqual(
            battleTransfer?.exclusiveOwner,
            .battle(battleInstanceID: battleID)
        )
    }

    func testFutureCapabilitiesDefaultDisabled() async {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.play, reason: "test")
        let capabilities = await arbiter.currentSnapshot().capabilities

        XCTAssertFalse(capabilities.contains(.crankRadioPlay))
        XCTAssertFalse(capabilities.contains(.crankRadioMicrophone))
        XCTAssertFalse(capabilities.contains(.hamReceiverPlay))
        XCTAssertFalse(capabilities.contains(.hamReceiverMicrophone))
        XCTAssertFalse(capabilities.contains(.handMicrophone))
    }

    func testDadFrameHasIndependentStableGateAndSharedLease() async throws {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(
            .microphone,
            surfaceID: .walkie,
            reason: "test"
        )
        await arbiter.updateTuringGate(
            .play,
            surfaceID: .dadFrame,
            reason: "test"
        )

        var snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.walkiePresentation, .microphone)
        XCTAssertEqual(snapshot.dadFramePresentation, .play)
        XCTAssertEqual(
            snapshot.capabilities,
            [
                .walkieMicrophone,
                .dadFramePlay,
                .doorOpen
            ]
        )

        let lease = try await arbiter.claimManualTuring(
            runID: "dadMemory",
            surfaceID: .dadFrame,
            source: "test"
        )
        snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(
            snapshot.exclusiveOwner,
            lease.owner
        )
        XCTAssertEqual(snapshot.walkiePresentation, .hidden)
        XCTAssertEqual(snapshot.dadFramePresentation, .hidden)
        XCTAssertEqual(snapshot.doorPresentation, .hidden)
    }

    private func XCTAssertThrowsStoryInteractionError(
        _ expected: StoryInteractionClaimError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected Story interaction claim to throw.", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? StoryInteractionClaimError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
