import XCTest
@testable import Gravitas_Plague

final class Chapter03ProgressStoreTests: XCTestCase {
    func testLegacyTunnelOnlyCompletionMigratesToProductionRoot() throws {
        let legacy = Chapter03ProgressSnapshot(
            schemaVersion: Chapter03ProgressSnapshot.currentSchemaVersion,
            contentRevision: "chapter03.lightTunnelTest.v2",
            checkpoint: .complete,
            revision: 7,
            sourceEventIDs: [UUID()],
            committedAt: Date(timeIntervalSince1970: 1)
        )

        let migrated = try Chapter03ProgressStore.decode(
            JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(migrated.contentRevision, "chapter03.v1")
        XCTAssertEqual(migrated.checkpoint, .root)
        XCTAssertEqual(migrated.revision, 8)
    }

    func testProgressCommitsOnlyLogicalCheckpoints() async throws {
        let suiteName = "Chapter03ProgressStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = Chapter03ProgressStore(defaults: defaults)

        let root = try await store.resetForReplay(sourceEventID: UUID())
        XCTAssertEqual(root.checkpoint, .root)
        let bikerPending = try await store.commit(
            .bikerBattlePending,
            sourceEventID: UUID()
        )
        XCTAssertEqual(bikerPending.checkpoint, .bikerBattlePending)
        let bikerCompleted = try await store.commit(
            .bikerBattleCompleted,
            sourceEventID: UUID()
        )
        XCTAssertEqual(bikerCompleted.checkpoint, .bikerBattleCompleted)
        let walkie = try await store.commit(
            .walkieCompleted,
            sourceEventID: UUID()
        )
        XCTAssertEqual(walkie.checkpoint, .walkieCompleted)
        let ham = try await store.commit(
            .hamCompleted,
            sourceEventID: UUID()
        )
        XCTAssertEqual(ham.checkpoint, .hamCompleted)
        let continuity = try await store.commit(
            .continuityBroadcastCompleted,
            sourceEventID: UUID()
        )
        XCTAssertEqual(continuity.checkpoint, .continuityBroadcastCompleted)
        let mikePending = try await store.commit(
            .mikeBattlePending,
            sourceEventID: UUID()
        )
        XCTAssertEqual(mikePending.checkpoint, .mikeBattlePending)
        let heavenPending = try await store.commit(
            .heavenTransitionPending,
            sourceEventID: UUID()
        )
        XCTAssertEqual(heavenPending.checkpoint, .heavenTransitionPending)
        let tunnelPending = try await store.commit(
            .lightTunnelPending,
            sourceEventID: UUID()
        )
        XCTAssertEqual(tunnelPending.checkpoint, .lightTunnelPending)
        let end = try await store.commit(
            .endCardPending,
            sourceEventID: UUID()
        )
        XCTAssertEqual(end.checkpoint, .endCardPending)
        XCTAssertGreaterThan(end.revision, root.revision)
    }

    func testMikeBattleCheckpointDoesNotAdvanceAtTerminalPunch() async throws {
        let suiteName = "Chapter03ProgressStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = Chapter03ProgressStore(defaults: defaults)

        _ = try await store.commit(.mikeBattlePending, sourceEventID: UUID())

        let snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot?.checkpoint, .mikeBattlePending)
    }

    func testBackwardCheckpointCannotReplaceEndCardPending() async throws {
        let suiteName = "Chapter03ProgressStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = Chapter03ProgressStore(defaults: defaults)
        _ = try await store.commit(.endCardPending, sourceEventID: UUID())
        let value = try await store.commit(
            .lightTunnelPending,
            sourceEventID: UUID()
        )
        XCTAssertEqual(value.checkpoint, .endCardPending)
    }
}
