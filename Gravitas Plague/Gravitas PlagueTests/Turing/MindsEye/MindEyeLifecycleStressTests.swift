import XCTest

@testable import Gravitas_Plague

final class MindEyeLifecycleStressTests: XCTestCase {
    func testOneHundredSuppressionCyclesLeaveNoClaims() async throws {
        let hub = MindEyePhysicalCharacterPresenceHub()
        for index in 0..<100 {
            let lease = try await hub.acquire(
                characterID: .bigMike,
                scope: .allPresentations,
                sourceID: "chapter03.mikeBattle.stress.\(index)",
                reason: "stress"
            )
            await hub.release(lease, reason: "stress")
        }
        let snapshot = await hub.currentSnapshot()
        XCTAssertTrue(snapshot.claims.isEmpty)
        XCTAssertEqual(snapshot.generation, 200)
    }
}
