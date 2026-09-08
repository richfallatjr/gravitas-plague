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

    func testFinalInvincibleDeadlineIsFiveSecondsBeforeActualPlaybackEnd() {
        XCTAssertEqual(
            Chapter03MikeFinalInvincibleDeadlinePolicy.delaySeconds(
                playbackDurationSeconds: 53.123651
            ),
            48.123651,
            accuracy: 0.000_001
        )
    }

    func testShortPlaybackEntersFinalInvincibleModeImmediately() {
        XCTAssertEqual(
            Chapter03MikeFinalInvincibleDeadlinePolicy.delaySeconds(
                playbackDurationSeconds: 4
            ),
            0
        )
    }

    func testInvalidPlaybackDurationDoesNotArmDeadline() {
        XCTAssertNil(
            Chapter03MikeFinalInvincibleDeadlinePolicy.delaySeconds(
                playbackDurationSeconds: -.infinity
            )
        )
        XCTAssertNil(
            Chapter03MikeFinalInvincibleDeadlinePolicy.delaySeconds(
                playbackDurationSeconds: -1
            )
        )
    }
}
