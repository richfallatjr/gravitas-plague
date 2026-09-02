import XCTest
@testable import Gravitas_Plague

final class Chapter03MikePostDefeatReactionPolicyTests: XCTestCase {
    func testProtectedModePreservesFullBodyReactionWithoutDamage() {
        XCTAssertEqual(
            Chapter03MikePostDefeatReactionPolicy.enemyDamageDisposition(
                postDefeatMode: true,
                finalInvincibleReactionMode: false
            ),
            .feedbackOnly
        )
    }

    func testFinalFiveSecondsUseExistingInvincibleReaction() {
        XCTAssertEqual(
            Chapter03MikePostDefeatReactionPolicy.enemyDamageDisposition(
                postDefeatMode: true,
                finalInvincibleReactionMode: true
            ),
            .headSnapAndImpactOnly
        )
        XCTAssertEqual(
            Chapter03MikePostDefeatReactionPolicy
                .shouldUseFinalInvincibleReaction(
                    remainingPlaybackSeconds: 5
                ),
            true
        )
    }

    func testInvincibleReactionWaitsUntilFiveSecondsRemain() {
        XCTAssertFalse(
            Chapter03MikePostDefeatReactionPolicy
                .shouldUseFinalInvincibleReaction(
                    remainingPlaybackSeconds: 5.001
                )
        )
        XCTAssertFalse(
            Chapter03MikePostDefeatReactionPolicy
                .shouldUseFinalInvincibleReaction(
                    remainingPlaybackSeconds: nil
                )
        )
    }
}
