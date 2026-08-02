import Foundation
import XCTest
@testable import Gravitas_Plague

@MainActor
final class Chapter01DadFinalBattleTests: XCTestCase {
    func testDefinitionLocksAuthoredTimelineAndPortalContract() throws {
        let definition = try Chapter01DadFinalBattleDefinitionStore().load()

        XCTAssertEqual(definition.battleID, "chapter01.dadFinalBattle.001")
        XCTAssertEqual(
            definition.trigger.checkpoint,
            Chapter01Checkpoint.preDadFinalBattleReady.rawValue
        )
        XCTAssertEqual(definition.enemy.characterID, "dad")
        XCTAssertEqual(definition.enemy.anchorIDs, [
            "zombie_a1", "zombie_a2", "zombie_a3"
        ])
        XCTAssertEqual(definition.enemy.idleDurationSeconds, 5)
        XCTAssertEqual(definition.enemy.turnCount, 2)
        XCTAssertTrue(definition.door.playerMayOpenDuringPortalApproach)
        XCTAssertEqual(definition.music.damageEnableAtMediaTimeSeconds, 60)
        XCTAssertEqual(definition.music.fadeOutDurationSeconds, 2)
        XCTAssertEqual(definition.enemy.removalDelayAfterMusicEndSeconds, 1)
        XCTAssertEqual(
            try definition.musicTimedRichCue.triggerMediaTimeSeconds,
            30
        )
        XCTAssertEqual(
            definition.playerDamage.confirmedHitsToKillAfterEnable,
            5
        )
    }

    func testDadStoryAcceptedHitCapacityIsDoubleHordeRange() {
        XCTAssertEqual(
            Chapter01DadBattleEnemyFactory.storyAcceptedHitCapacity(
                hordeCapacity: 3,
                multiplier: 2
            ),
            6
        )
        XCTAssertEqual(
            Chapter01DadBattleEnemyFactory.storyAcceptedHitCapacity(
                hordeCapacity: 5,
                multiplier: 2
            ),
            10
        )
    }

    func testPlayerDamageBeginsAtExactSoundtrackMinute() {
        let policy = Chapter01DadBattlePlayerDamagePolicy(
            damageEnableMediaTime: 60
        )

        XCTAssertEqual(
            policy.disposition(soundtrackMediaTime: nil),
            .feedbackOnly
        )
        XCTAssertEqual(
            policy.disposition(soundtrackMediaTime: 59.999),
            .feedbackOnly
        )
        XCTAssertEqual(
            policy.disposition(soundtrackMediaTime: 60.000),
            .applyDamage
        )
        XCTAssertEqual(
            policy.disposition(soundtrackMediaTime: 120),
            .applyDamage
        )
    }

    func testDadHealthMutationUsesTheSameExactSoundtrackMinuteGate() {
        let policy = Chapter01DadBattlePlayerDamagePolicy(
            damageEnableMediaTime: 60
        )

        XCTAssertEqual(
            policy.enemyDamageDisposition(soundtrackMediaTime: nil),
            .feedbackOnly
        )
        XCTAssertEqual(
            policy.enemyDamageDisposition(soundtrackMediaTime: 59.999),
            .feedbackOnly
        )
        XCTAssertEqual(
            policy.enemyDamageDisposition(soundtrackMediaTime: 60.000),
            .applyDamage
        )
    }

    func testFifthConfirmedPostGateContactIsTerminal() {
        let budget = StoryPlayerHitBudget(maximumConfirmedHits: 5)

        for expectedCount in 1...4 {
            XCTAssertFalse(budget.registerConfirmedHit())
            XCTAssertEqual(budget.snapshot().confirmedHits, expectedCount)
        }
        XCTAssertTrue(budget.registerConfirmedHit())
        XCTAssertEqual(budget.snapshot().confirmedHits, 5)
        XCTAssertTrue(budget.snapshot().terminal)
    }

    func testRichCuesAreAuthoredGlobalRecordingsOnly() throws {
        let definition = try Chapter01DadFinalBattleDefinitionStore().load()
        let store = TuringPrerecordingStore()

        for cue in definition.richPrerecordedCues {
            let descriptor = try store.descriptor(id: cue.prerecordingID)
            XCTAssertEqual(cue.outputRoute, "roomGlobal")
            XCTAssertEqual(cue.gainDB, -5)
            XCTAssertEqual(descriptor.speaker, "rich")
            XCTAssertEqual(descriptor.transcriptMode, .none)
            XCTAssertTrue(descriptor.transcript.isEmpty)
            XCTAssertFalse(descriptor.audioFile.isEmpty)
        }
        XCTAssertFalse(definition.richPrerecordedCuePolicy.usesGeneratedSpeech)
        XCTAssertFalse(definition.richPrerecordedCuePolicy.usesWalkieEnvelope)
    }

    func testContinueDestinationRemainsPreDadBattleCheckpoint() {
        XCTAssertEqual(
            Chapter01Checkpoint.preDadFinalBattleReady
                .supportedContinuationCheckpoint,
            .preDadFinalBattleReady
        )
    }
}
