import AVFoundation
import RealityKit
import XCTest
@testable import Gravitas_Plague

@MainActor
final class Battle01ContractTests: XCTestCase {
    func testDefinitionLocksAuthoredSequenceAndAuthorities() throws {
        let definition = try Battle01DefinitionStore().load()

        XCTAssertEqual(definition.battleID, "prologue.battle01.mrsDempsey")
        XCTAssertEqual(definition.trigger.scriptPointID, "prologue.scriptPoint03")
        XCTAssertTrue(definition.trigger.requiresSuccessfulActualPlaybackCompletion)
        XCTAssertEqual(definition.enemy.anchorIDs, ["zombie_a1", "zombie_a2", "zombie_a3"])
        XCTAssertEqual(definition.enemy.idleDurationSeconds, 5, accuracy: 0.0001)
        XCTAssertEqual(definition.enemy.turnClipID, "turn_right_90")
        XCTAssertEqual(definition.enemy.turnCount, 2)
        XCTAssertEqual(definition.enemy.turnDegreesPerCompletion, 90, accuracy: 0.0001)
        XCTAssertEqual(definition.enemy.walkClipID, "unstable_walk_01")
        XCTAssertFalse(definition.enemy.retainCorpseAfterDeath)
        XCTAssertEqual(
            definition.enemy.corpseRemovalDelaySeconds,
            0,
            accuracy: 0.0001
        )
        XCTAssertTrue(definition.completion.removeCorpse)

        XCTAssertTrue(definition.portalHandoff.sourceIsAnimationAuthority)
        XCTAssertTrue(definition.portalHandoff.sourceIsCombatAuthority)
        XCTAssertFalse(definition.portalHandoff.mirrorHasCollision)
        XCTAssertFalse(definition.portalHandoff.mirrorHasAudio)
        XCTAssertFalse(definition.portalHandoff.mirrorHasDamageAuthority)
    }

    func testBattleTurnPreservesAuthoredYawWhileApplyingVisualCorrection() {
        let authored = JockRuntimeClipOverride(
            entryHeadingDegrees: 0,
            exitHeadingDegrees: -90,
            commitRootYawOnCompletion: true
        )

        let resolved = JockRetargetTestController.scriptedTurnRuntimeOverride(
            authoredOverride: authored,
            visualHeadingCorrectionDegrees: 180
        )

        XCTAssertEqual(resolved.entryHeadingDegrees, -180, accuracy: 0.0001)
        XCTAssertEqual(resolved.exitHeadingDegrees, -270, accuracy: 0.0001)
        XCTAssertEqual(resolved.yawDeltaDegrees, -90, accuracy: 0.0001)
        XCTAssertTrue(resolved.commitRootYawOnCompletion)
    }

    func testStoryGrandmaAcceptedHitCapacityIsDoubled() {
        XCTAssertEqual(
            Battle01EnemyFactory.storyHitsToKill(currentHitsToKill: 3),
            6
        )
        XCTAssertEqual(
            Battle01EnemyFactory.storyHitsToKill(currentHitsToKill: 5),
            10
        )
    }

    func testMusicRequiresScriptPoint03CompletionAndOpenDoor() {
        var noScriptCompletion = Battle01MusicStartGate()
        XCTAssertFalse(
            noScriptCompletion.claimIfEligible(
                doorState: .open,
                mediaPrepared: true
            )
        )

        var closedDoor = Battle01MusicStartGate()
        closedDoor.recordScriptPoint03TTSCompletion()
        XCTAssertFalse(
            closedDoor.claimIfEligible(
                doorState: .closed,
                mediaPrepared: true
            )
        )

        var eligible = Battle01MusicStartGate()
        eligible.recordScriptPoint03TTSCompletion()
        XCTAssertTrue(
            eligible.claimIfEligible(
                doorState: .open,
                mediaPrepared: true
            )
        )
        XCTAssertFalse(
            eligible.claimIfEligible(
                doorState: .open,
                mediaPrepared: true
            )
        )
    }

    func testBattleMediaIsFileBackedAndNonGenerated() throws {
        let definition = try Battle01DefinitionStore().load()
        let soundtrackURL = try Battle01DefinitionStore().soundtrackURL(for: definition)
        let descriptor = try TuringPrerecordingStore().descriptor(
            id: definition.richPrerecording.prerecordingID
        )
        let richURL = try TuringPrerecordingStore().audioURL(for: descriptor)

        let soundtrack = try AVAudioPlayer(contentsOf: soundtrackURL)
        let rich = try AVAudioPlayer(contentsOf: richURL)
        XCTAssertGreaterThan(soundtrack.duration, 0)
        XCTAssertGreaterThan(rich.duration, 0)
        XCTAssertFalse(definition.music.loop)
        XCTAssertEqual(
            definition.music.trigger,
            "scriptPoint03ActualTTSCompletionAndDoorOpen"
        )
        XCTAssertEqual(
            definition.music.stop,
            "aftermathCrossfadeOrNaturalFileCompletion"
        )
        XCTAssertEqual(definition.aftermathMusic.file, "cabin-aftermath-loop.mp3")
        XCTAssertTrue(definition.aftermathMusic.loop)
        XCTAssertEqual(
            definition.aftermathMusic.delayAfterGrandmaDeathMinSeconds,
            3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            definition.aftermathMusic.delayAfterGrandmaDeathMaxSeconds,
            5,
            accuracy: 0.0001
        )
        XCTAssertEqual(definition.aftermathMusic.targetDecibels, -22, accuracy: 0.0001)
        XCTAssertEqual(definition.aftermathMusic.stop, "prologueTeardown")
        XCTAssertEqual(definition.richPrerecording.outputRoute, "roomGlobal")
        XCTAssertFalse(definition.richPrerecording.playWalkieOpenSound)
        XCTAssertFalse(definition.richPrerecording.playWalkieSendSound)
        XCTAssertFalse(definition.richPrerecording.playStatic)
        XCTAssertFalse(definition.richPrerecording.generatePromptVoice)
    }

    func testAftermathMusicIsBundledAndAudible() throws {
        let definition = try Battle01DefinitionStore().load()
        let url = try Battle01DefinitionStore().aftermathSoundtrackURL(
            for: definition
        )
        let player = try AVAudioPlayer(contentsOf: url)

        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertEqual(
            Battle01SoundtrackController.linearGain(decibels: -22),
            0.07943282,
            accuracy: 0.0001
        )
    }

    func testRichPrerecordingDescriptorIsAuthoredRichAudio() throws {
        let descriptor = try TuringPrerecordingStore().descriptor(
            id: "prologue.rich.battle01.mrsDempsey.001"
        )

        XCTAssertEqual(descriptor.speaker, "rich")
        XCTAssertEqual(descriptor.voiceID, "rich_base_clone_v1")
        XCTAssertEqual(descriptor.audioFile, "pr-rich-battle-mrs-dempsey.mp3")
        XCTAssertEqual(descriptor.transcriptMode, .manual)
        XCTAssertTrue(descriptor.transcript.contains("Mrs. Dempsey"))
        XCTAssertEqual(
            descriptor.voicePromptIntent,
            "No generated continuation. Authored Battle01 media only."
        )
    }

    func testDoorBundleContainsAllBattleAnchors() async throws {
        let url = try TuringResourceLoader.resourceURL(
            resourcePath: "Turing/Props/turing_story_door_bundle_v1.usdz"
        )
        let root = try await Entity(contentsOf: url)

        XCTAssertNotNil(root.findEntity(named: "zombie_a1"))
        XCTAssertNotNil(root.findEntity(named: "zombie_a2"))
        XCTAssertNotNil(root.findEntity(named: "zombie_a3"))
        XCTAssertNotNil(root.findEntity(named: "TuringStoryDoorPortalPlane"))
    }
}
