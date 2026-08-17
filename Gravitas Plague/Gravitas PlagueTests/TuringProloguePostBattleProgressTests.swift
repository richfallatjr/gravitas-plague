import Foundation
import XCTest
@testable import Gravitas_Plague

@MainActor
final class TuringProloguePostBattleProgressTests: XCTestCase {
    func testBattleReleaseUnlocksAllFourAsPlay() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let snapshot = try await store.unlockAfterBattleRuntimeReleased()

        XCTAssertTrue(snapshot.hubUnlocked)
        XCTAssertEqual(snapshot.boundaryState, .notReady)
        XCTAssertEqual(snapshot.deviceStates.count, 4)
        XCTAssertTrue(snapshot.deviceStates.values.allSatisfy { $0 == .play })
        XCTAssertTrue(snapshot.completionEvidence.isEmpty)
    }

    func testCanonicalPostBattleOrderIsCrankWalkieHamDad() {
        XCTAssertEqual(
            TuringProloguePostBattleDeviceCatalog.ordered.map(\.deviceID),
            [.crankRadio, .walkie, .hamReceiver, .dadPhoto]
        )
    }

    func testOrderedRevealAcceptsOnlyFirstIncompleteDevice() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.unlockAfterBattleRuntimeReleased()

        _ = try await store.requirePlayable(.crankRadio)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.requirePlayable(.walkie)
        }

        _ = try await store.completeDevice(
            evidence: makeEvidence(device: .crankRadio)
        )
        _ = try await store.requirePlayable(.walkie)
    }

    func testAllTwentyFourCompletionOrdersPersistTheFourthBeforeTransition() async throws {
        for order in permutations(ProloguePostBattleDeviceID.allCases) {
            let (store, defaults, suite) = try makeStore()
            defer { defaults.removePersistentDomain(forName: suite) }
            _ = try await store.unlockAfterBattleRuntimeReleased()

            var finalEventID: UUID?
            for (index, device) in order.enumerated() {
                let evidence = makeEvidence(device: device)
                if index == 3 { finalEventID = evidence.terminalCompletionEventID }
                let result = try await store.completeDevice(evidence: evidence)
                XCTAssertEqual(
                    result.becameChapterTransitionPending,
                    index == 3,
                    "order=\(order.map(\.rawValue))"
                )
                XCTAssertEqual(result.snapshot.state(for: device), .microphone)
                XCTAssertEqual(
                    result.snapshot.boundaryState,
                    index == 3 ? .chapterTransitionPending : .notReady
                )
                for remaining in order.dropFirst(index + 1) {
                    XCTAssertEqual(result.snapshot.state(for: remaining), .play)
                }
            }

            let reloaded = TuringProloguePostBattleProgressStore(defaults: defaults)
            let persisted = try XCTUnwrap(try await reloaded.load())
            XCTAssertTrue(persisted.allDevicesCompleted)
            XCTAssertEqual(persisted.boundaryState, .chapterTransitionPending)
            XCTAssertEqual(persisted.boundaryEventID, finalEventID)
            XCTAssertEqual(persisted.completionEvidence.count, 4)
        }
    }

    func testTitleFailureDoesNotRollBackFourthDevice() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.unlockAfterBattleRuntimeReleased()

        for device in ProloguePostBattleDeviceID.allCases {
            _ = try await store.completeDevice(evidence: makeEvidence(device: device))
        }

        let reloaded = TuringProloguePostBattleProgressStore(defaults: defaults)
        let persisted = try XCTUnwrap(try await reloaded.load())
        XCTAssertTrue(persisted.allDevicesCompleted)
        XCTAssertEqual(persisted.boundaryState, .chapterTransitionPending)
        XCTAssertTrue(persisted.deviceStates.values.allSatisfy { $0 == .microphone })
    }

    func testChapterStartCommitsPendingBoundary() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.unlockAfterBattleRuntimeReleased()
        for device in ProloguePostBattleDeviceID.allCases {
            _ = try await store.completeDevice(evidence: makeEvidence(device: device))
        }
        let pending = try XCTUnwrap(try await store.load())
        let eventID = try XCTUnwrap(pending.boundaryEventID)

        let started = try await store.markChapter01Started(
            boundaryEventID: eventID
        )

        XCTAssertEqual(started.boundaryState, .chapter01Started)
        XCTAssertTrue(started.allDevicesCompleted)
    }

    func testADevicePersistsIndependentlyWhenCompletedFirst() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.unlockAfterBattleRuntimeReleased()

        _ = try await store.completeDevice(
            evidence: makeEvidence(device: .crankRadio)
        )

        let reloaded = TuringProloguePostBattleProgressStore(defaults: defaults)
        let snapshot = try XCTUnwrap(try await reloaded.load())
        XCTAssertEqual(snapshot.state(for: .crankRadio), .microphone)
        XCTAssertEqual(snapshot.state(for: .walkie), .play)
        XCTAssertEqual(snapshot.state(for: .dadPhoto), .play)
        XCTAssertEqual(snapshot.state(for: .hamReceiver), .play)
        XCTAssertEqual(snapshot.boundaryState, .notReady)
    }

    func testSecondBattleReleaseDoesNotResetCompletedDevices() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.unlockAfterBattleRuntimeReleased()
        _ = try await store.completeDevice(evidence: makeEvidence(device: .walkie))

        let restored = try await store.unlockAfterBattleRuntimeReleased()

        XCTAssertEqual(restored.state(for: .walkie), .microphone)
        XCTAssertEqual(restored.state(for: .dadPhoto), .play)
        XCTAssertEqual(restored.state(for: .crankRadio), .play)
        XCTAssertEqual(restored.state(for: .hamReceiver), .play)
    }

    func testSnapshotUsesOneAtomicJSONValue() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.unlockAfterBattleRuntimeReleased()
        _ = try await store.completeDevice(evidence: makeEvidence(device: .hamReceiver))

        XCTAssertNotNil(
            defaults.data(
                forKey: TuringProloguePostBattleProgressStore.saveKey
            )
        )
        XCTAssertNil(defaults.object(forKey: "story.prologue.postBattle.progress.v1"))
        for device in ProloguePostBattleDeviceID.allCases {
            XCTAssertNil(defaults.object(forKey: "postBattle.\(device.rawValue)"))
        }
    }

    func testSnapshotValidationRejectsInconsistentState() throws {
        let date = Date()
        let base = ProloguePostBattleSnapshot.initialUnlocked(at: date)

        var missingKey = base
        missingKey.deviceStates.removeValue(forKey: .crankRadio)
        XCTAssertThrowsError(try missingKey.validated())

        var playWithEvidence = base
        playWithEvidence.completionEvidence[.walkie] = .live(
            makeEvidence(device: .walkie)
        )
        XCTAssertThrowsError(try playWithEvidence.validated())

        var microphoneWithoutEvidence = base
        microphoneWithoutEvidence.deviceStates[.dadPhoto] = .microphone
        XCTAssertThrowsError(try microphoneWithoutEvidence.validated())

        var pendingBeforeFour = base
        pendingBeforeFour.boundaryState = .chapterTransitionPending
        pendingBeforeFour.boundaryEventID = UUID()
        XCTAssertThrowsError(try pendingBeforeFour.validated())

        var startedBeforeFour = base
        startedBeforeFour.boundaryState = .chapter01Started
        startedBeforeFour.boundaryEventID = UUID()
        XCTAssertThrowsError(try startedBeforeFour.validated())
    }

    func testCompletionRequiresUnlockedPlayableDevice() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        do {
            _ = try await store.completeDevice(
                evidence: makeEvidence(device: .dadPhoto)
            )
            XCTFail("Expected a locked-hub rejection.")
        } catch ProloguePostBattleProgressError.hubNotUnlocked {
        }
    }

    func testDuplicateTerminalEventDoesNotAdvanceRevisionTwice() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.unlockAfterBattleRuntimeReleased()
        let evidence = makeEvidence(device: .dadPhoto)

        let first = try await store.completeDevice(evidence: evidence)
        let duplicate = try await store.completeDevice(evidence: evidence)

        XCTAssertTrue(first.deviceWasNewlyCompleted)
        XCTAssertFalse(duplicate.deviceWasNewlyCompleted)
        XCTAssertEqual(first.snapshot.revision, duplicate.snapshot.revision)
    }

    func testLegacyMigrationPreservesVerifiedDevicesAndResetsCrank() async throws {
        let (_, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "progress": [
                "unlocked": true,
                "completedDevices": [
                    "walkie", "dadPhoto", "crankRadio", "hamReceiver"
                ]
            ],
            "revision": 7,
            "contentRevision": "prologue.postBattle.v3"
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: "story.prologue.postBattle.progress.v1"
        )

        let migratedStore = TuringProloguePostBattleProgressStore(defaults: defaults)
        let migrated = try XCTUnwrap(try await migratedStore.load())

        XCTAssertEqual(migrated.state(for: .walkie), .microphone)
        XCTAssertEqual(migrated.state(for: .dadPhoto), .microphone)
        XCTAssertEqual(migrated.state(for: .hamReceiver), .microphone)
        XCTAssertEqual(migrated.state(for: .crankRadio), .play)
        XCTAssertEqual(migrated.boundaryState, .notReady)
        let migrationIDs = Set(
            migrated.completionEvidence.values.compactMap { evidence -> UUID? in
                guard case .trustedLegacyMigration(let value) = evidence else {
                    return nil
                }
                return value.migrationID
            }
        )
        XCTAssertEqual(migrationIDs.count, 1)
        XCTAssertNil(
            defaults.object(forKey: "story.prologue.postBattle.progress.v1")
        )
    }

    func testUnknownLegacyRevisionIsRejected() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "progress": [
                "unlocked": true,
                "completedDevices": ["crankRadio"]
            ],
            "revision": 7,
            "contentRevision": "unknown.revision"
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: "story.prologue.postBattle.progress.v1"
        )

        do {
            _ = try await store.load()
            XCTFail("Expected an unknown legacy revision rejection.")
        } catch ProloguePostBattleProgressError.unsupportedLegacySnapshot {
        }
        XCTAssertNotNil(
            defaults.object(forKey: "story.prologue.postBattle.progress.v1")
        )
    }

    func testExactDeviceContractsAndTriggers() {
        XCTAssertEqual(
            TuringProloguePostBattleDeviceCatalog.walkie.rootScriptPointID,
            "prologue.scriptPoint04"
        )
        XCTAssertEqual(
            TuringProloguePostBattleDeviceCatalog.walkie.terminalScriptPointID,
            "prologue.scriptPoint05"
        )
        XCTAssertTrue(
            TuringProloguePostBattleDeviceCatalog.walkie.terminalTrigger.matches(
                .priorScriptPointCompleted(
                    parentScriptPointID: "prologue.scriptPoint04"
                )
            )
        )
        XCTAssertTrue(
            TuringProloguePostBattleDeviceCatalog.crankRadio.terminalTrigger
                .matches(.userPlay)
        )
        XCTAssertFalse(
            TuringProloguePostBattleDeviceCatalog.hamReceiver.terminalTrigger
                .matches(.userPlay)
        )
    }

    private func makeEvidence(
        device: ProloguePostBattleDeviceID
    ) -> ProloguePostBattleCompletionEvidence.Live {
        let contract = TuringProloguePostBattleDeviceCatalog.byID[device]!
        return .init(
            deviceID: device,
            rootScriptPointID: contract.rootScriptPointID,
            terminalScriptPointID: contract.terminalScriptPointID,
            activationID: UUID(),
            flowSequenceID: UUID(),
            flowInstanceID: UUID(),
            terminalCompletionEventID: UUID(),
            triggerDescription: "test",
            actualTerminalPlaybackCompletedAt: Date()
        )
    }

    private func makeStore() throws -> (
        TuringProloguePostBattleProgressStore,
        UserDefaults,
        String
    ) {
        let suite = "TuringProloguePostBattleProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (
            TuringProloguePostBattleProgressStore(defaults: defaults),
            defaults,
            suite
        )
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard values.count > 1 else { return [values] }
        return values.enumerated().flatMap { index, value in
            var remainder = values
            remainder.remove(at: index)
            return permutations(remainder).map { [value] + $0 }
        }
    }

    private func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected an error.", file: file, line: line)
        } catch {
        }
    }
}
