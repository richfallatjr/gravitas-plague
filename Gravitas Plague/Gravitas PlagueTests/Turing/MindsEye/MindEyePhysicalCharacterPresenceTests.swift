import XCTest

@testable import Gravitas_Plague

final class MindEyePhysicalCharacterPresenceTests: XCTestCase {
    func testAllPresentationClaimSuppressesEveryCharacterAndReleasesExactly() async throws {
        let hub = MindEyePhysicalCharacterPresenceHub()
        let lease = try await hub.acquire(
            characterID: .bigMike,
            scope: .allPresentations,
            sourceID: "chapter03.mikeBattle.test",
            reason: "test"
        )

        var snapshot = await hub.currentSnapshot()
        XCTAssertTrue(snapshot.suppressesAllPresentations)
        XCTAssertTrue(snapshot.suppresses(characterID: .bigMike))
        XCTAssertTrue(snapshot.suppresses(characterID: .rich))

        await hub.release(lease, reason: "testComplete")
        snapshot = await hub.currentSnapshot()
        XCTAssertTrue(snapshot.claims.isEmpty)
        XCTAssertFalse(snapshot.suppressesAllPresentations)
    }

    func testStaleReleaseCannotClearNewerClaim() async throws {
        let hub = MindEyePhysicalCharacterPresenceHub()
        let stale = try await hub.acquire(
            characterID: .bigMike,
            scope: .allPresentations,
            sourceID: "chapter03.mikeBattle.stale",
            reason: "first"
        )
        await hub.release(stale, reason: "replace")
        let current = try await hub.acquire(
            characterID: .bigMike,
            scope: .allPresentations,
            sourceID: "chapter03.mikeBattle.current",
            reason: "second"
        )

        await hub.release(stale, reason: "lateCallback")
        let snapshot = await hub.currentSnapshot()
        XCTAssertEqual(snapshot.claims.map(\.lease), [current])
    }

    func testInvalidSourceIDIsRejected() async {
        let hub = MindEyePhysicalCharacterPresenceHub()
        do {
            _ = try await hub.acquire(
                characterID: .bigMike,
                scope: .allPresentations,
                sourceID: "../invalid",
                reason: "test"
            )
            XCTFail("Expected an invalid source ID to fail")
        } catch let failure as MindEyeFailure {
            XCTAssertEqual(failure.code, .physicalPresenceClaimInvalid)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
