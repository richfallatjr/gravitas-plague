import XCTest
@testable import Gravitas_Plague

final class Chapter03ProgressStoreTests: XCTestCase {
    func testProgressCommitsOnlyLogicalCheckpoints() async throws {
        let suiteName = "Chapter03ProgressStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = Chapter03ProgressStore(defaults: defaults)

        let root = try await store.resetForReplay(sourceEventID: UUID())
        XCTAssertEqual(root.checkpoint, .root)
        let pending = try await store.commit(
            .lightTunnelPending,
            sourceEventID: UUID()
        )
        XCTAssertEqual(pending.checkpoint, .lightTunnelPending)
        let end = try await store.commit(
            .endCardPending,
            sourceEventID: UUID()
        )
        XCTAssertEqual(end.checkpoint, .endCardPending)
        XCTAssertGreaterThan(end.revision, root.revision)
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
