import Foundation
import XCTest

@testable import Gravitas_Plague

@MainActor
final class Chapter02ContractTests: XCTestCase {
    private let scriptPointIDs = [
        "chapter02.crankRadio.broadcaster.missingPersons.001",
        "chapter02.hamReceiver.dad.script01",
        "chapter02.hamReceiver.rich.script02",
        "chapter02.hamReceiver.dad.script03",
        "chapter02.walkie.bigMike.script01",
        "chapter02.walkie.rich.script02",
        "chapter02.walkie.bigMike.script03",
        "chapter02.dadFrame.rich.dadDisappeared.001",
        "chapter02.crankRadio.broadcaster.gridFailure.002",
        "chapter02.room.rich.windowRecognition.001",
        "chapter02.room.rich.womanBattle.001",
        "chapter02.hamReceiver.rich.revelation.001",
        "chapter02.hamReceiver.cateye81.revelation.002",
        "chapter02.crankRadio.broadcaster.gravitasPSA.003"
    ]

    private let promptVoiceIDs = [
        "chapter02.broadcaster.missingPersons.promptVoice.001",
        "chapter02.dad.hamReceiver.script01.promptVoice.001",
        "chapter02.rich.hamReceiver.script02.promptVoice.001",
        "chapter02.dad.hamReceiver.script03.promptVoice.001",
        "chapter02.bigMike.walkie.script01.promptVoice.001",
        "chapter02.rich.walkie.script02.promptVoice.001",
        "chapter02.bigMike.walkie.script03.promptVoice.001",
        "chapter02.rich.dadFrame.dadDisappeared.promptVoice.001",
        "chapter02.broadcaster.gridFailure.promptVoice.002",
        "chapter02.rich.hamReceiver.revelation.promptVoice.001",
        "chapter02.cateye81.hamReceiver.revelation.promptVoice.002",
        "chapter02.broadcaster.gravitasPSA.promptVoice.003"
    ]

    func testChapterTwoPickerEntryAndTitleCardAreExact() throws {
        let episode = try XCTUnwrap(
            TuringEpisodeCatalog.descriptor(for: .chapter02)
        )

        XCTAssertEqual(episode.title, "Chapter 2")
        XCTAssertEqual(episode.subtitle, "The Night the Lights Went Out")
        XCTAssertEqual(episode.availability, .unlocked)
        XCTAssertEqual(episode.contentRevision, "chapter02.v1")
        XCTAssertEqual(episode.stripArtwork, .chapter02Strip)
        XCTAssertEqual(StoryTitleCardCatalog.chapter02.title, "Chapter 2")
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter02.subtitle,
            "The Night the Lights Went Out"
        )
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter02.fadeToBlackSeconds,
            .milliseconds(750)
        )
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter02.holdSeconds,
            .milliseconds(7_500)
        )
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter02.fadeFromBlackSeconds,
            .milliseconds(750)
        )
    }

    func testChapterTwoSurfaceSequenceUsesSevenIsolatedBindings() {
        let bindings = [
            TuringStorySurfaceFlowBinding.chapter02CrankMissingPersons,
            .chapter02DadHam,
            .chapter02BigMikeWalkie,
            .chapter02DadPhoto,
            .chapter02CrankGridFailure,
            .chapter02PostBattleHam,
            .chapter02CrankGravitasPSA
        ]

        XCTAssertEqual(
            bindings.map(\.rootScriptPointID),
            [
                scriptPointIDs[0],
                scriptPointIDs[1],
                scriptPointIDs[4],
                scriptPointIDs[7],
                scriptPointIDs[8],
                scriptPointIDs[11],
                scriptPointIDs[13]
            ]
        )
        XCTAssertEqual(Set(bindings.map(\.conversationKey)).count, 7)
        XCTAssertEqual(
            bindings.map(\.interactionSurface),
            [
                .crankRadio,
                .hamReceiver,
                .walkie,
                .dadFrame,
                .crankRadio,
                .hamReceiver,
                .crankRadio
            ]
        )
    }

    func testChapterTwoProgressIsDurableMonotonicAndIdempotent() async throws {
        let suite = "Chapter02ContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Chapter02ProgressStore(defaults: defaults)

        _ = try await store.resetForReplay(sourceEventID: UUID())
        let eventID = UUID()
        let first = try await store.commit(
            .dadHamCompleted,
            sourceEventID: eventID
        )
        let duplicate = try await store.commit(
            .dadHamCompleted,
            sourceEventID: eventID
        )
        let backwards = try await store.commit(
            .missingPersonsCompleted,
            sourceEventID: UUID()
        )

        XCTAssertEqual(first.checkpoint, .dadHamCompleted)
        XCTAssertEqual(first.revision, duplicate.revision)
        XCTAssertEqual(backwards.checkpoint, .dadHamCompleted)

        let reloaded = Chapter02ProgressStore(defaults: defaults)
        let reloadedSnapshot = await reloaded.currentSnapshot()
        let restored = try XCTUnwrap(reloadedSnapshot)
        XCTAssertEqual(restored.checkpoint, .dadHamCompleted)
        XCTAssertEqual(restored.contentRevision, "chapter02.v1")
    }

    func testAllChapterTwoScriptPointsAndPrerecordingsLoad() throws {
        let flowStore = TuringFlowDescriptorStore()
        let prerecordingStore = TuringPrerecordingStore()

        for id in scriptPointIDs {
            let flow = try flowStore.require(id)
            XCTAssertEqual(flow.scriptPointID, id)
            let prerecording = try prerecordingStore.descriptor(
                id: flow.transmission.prerecordingID
            )
            XCTAssertFalse(prerecording.transcript.isEmpty, id)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: try prerecordingStore.audioURL(
                        for: prerecording
                    ).path
                ),
                id
            )
        }
    }

    func testAllAuthoredChapterTwoPromptVoicesLoad() throws {
        let store = TuringVoicePromptTriggerStore()

        for id in promptVoiceIDs {
            let descriptor = try store.descriptor(id: id)
            XCTAssertEqual(descriptor.voicePromptID, id)
            XCTAssertFalse(descriptor.intent.isEmpty, id)
            XCTAssertFalse(descriptor.characterProfileID.isEmpty, id)
            XCTAssertFalse(descriptor.effectiveCommunicationMedium.isEmpty, id)
        }
    }

    func testChapterTwoWalkieUsesPrologueStaticAndSendContracts() throws {
        let store = TuringFlowDescriptorStore()
        let rich = try store.require(
            "chapter02.walkie.rich.script02"
        )
        let mike = try store.require(
            "chapter02.walkie.bigMike.script03"
        )
        let prologueRich = try store.require("prologue.scriptPoint02")
        let prologueMike = try store.require("prologue.scriptPoint03")

        XCTAssertEqual(
            rich.transmission.commSFX,
            prologueRich.transmission.commSFX
        )
        XCTAssertTrue(
            TuringRichWalkieFlowRoute
                .usesIncomingStaticBeforePrerecording(
                    scriptPointID: rich.scriptPointID
                )
        )
        XCTAssertEqual(
            mike.transmission.computeStart,
            prologueMike.transmission.computeStart
        )
        XCTAssertEqual(
            mike.transmission.fixedLeadInSeconds,
            prologueMike.transmission.fixedLeadInSeconds
        )
        XCTAssertEqual(mike.transmission.fixedLeadInSeconds, 10)
    }

    func testWindowAndBattleRecognitionCuesArePrerecordedOnly() throws {
        let store = TuringFlowDescriptorStore()
        for id in [
            "chapter02.room.rich.windowRecognition.001",
            "chapter02.room.rich.womanBattle.001"
        ] {
            let flow = try store.require(id)
            XCTAssertNil(flow.transmission.voicePromptID, id)
            XCTAssertEqual(flow.transmission.computeStart, .none, id)
            XCTAssertEqual(flow.transmission.outputRoute, .roomGlobal, id)
        }
    }

    func testFinalPSAUsesFoundationBeforePRAndEndsOnMicrophone() throws {
        let flow = try TuringFlowDescriptorStore().require(
            "chapter02.crankRadio.broadcaster.gravitasPSA.003"
        )

        XCTAssertEqual(
            flow.transmission.computeStart,
            .foundationBeforePrerecording
        )
        XCTAssertEqual(flow.transmission.outputRoute, .crankRadioSpatial)
        XCTAssertEqual(flow.transmission.effectiveInteractionSurface, .crankRadio)
        XCTAssertEqual(
            flow.progression.interactionGateAfterCompletion,
            .microphone
        )
    }

    func testChapterTwoCrankFlowsDoNotUseGenericPreAlarm() {
        for scriptPointID in [
            "chapter02.crankRadio.broadcaster.missingPersons.001",
            "chapter02.crankRadio.broadcaster.gridFailure.002",
            "chapter02.crankRadio.broadcaster.gravitasPSA.003"
        ] {
            XCTAssertFalse(
                TuringBroadcasterCrankRadioFlowRoute
                    .usesEmergencyDataBurst(scriptPointID: scriptPointID),
                scriptPointID
            )
        }

        XCTAssertTrue(
            TuringBroadcasterCrankRadioFlowRoute
                .usesEmergencyDataBurst(
                    scriptPointID:
                        "prologue.crankRadio.broadcaster.broadcast.001"
                )
        )
        XCTAssertFalse(
            TuringBroadcasterCrankRadioFlowRoute
                .usesEmergencyDataBurst(
                    scriptPointID:
                        "chapter03.crankRadio.broadcaster.continuity.001"
                )
        )
    }

    func testChapterTwoBattleMusicUsesAuthoredLoopAndFinalCrankDucking() throws {
        XCTAssertEqual(Chapter02BattleMusicActor.targetGainDB, 0)
        XCTAssertTrue(Chapter02BattleMusicActor.postBattleGainDB.isInfinite)
        XCTAssertLessThan(Chapter02BattleMusicActor.postBattleGainDB, 0)
        XCTAssertEqual(
            Chapter02BattleMusicActor.resourcePath,
            "Turing/Audio/chapter02/battle-03-music.mp3"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try TuringResourceLoader.resourceURL(
                    resourcePath: Chapter02BattleMusicActor.resourcePath
                ).path
            )
        )
        XCTAssertTrue(
            Chapter02BattleMusicInteractionPolicy.ducksConversation(
                conversationKey:
                    TuringStorySurfaceFlowBinding.chapter02CrankGravitasPSA
                        .conversationKey
            )
        )
        XCTAssertFalse(
            Chapter02BattleMusicInteractionPolicy.ducksConversation(
                conversationKey:
                    TuringStorySurfaceFlowBinding.chapter02PostBattleHam
                        .conversationKey
            )
        )
    }

    func testChapterTwoTemplatesPresentPriorPRBeforeStoryIntent() throws {
        for path in [
            "Turing/Prompts/voicePrompt_chapter02CharacterIntent.txt",
            "Turing/Prompts/voicePrompt_chapter02Broadcaster.txt",
            "Turing/Prompts/voicePrompt_chapter02CatEye81.txt"
        ] {
            let url = try TuringResourceLoader.resourceURL(resourcePath: path)
            let template = try String(contentsOf: url, encoding: .utf8)
            let prior = try XCTUnwrap(
                template.range(of: "{{prerecordingTranscript}}")
            )
            let intent = try XCTUnwrap(template.range(of: "{{storyIntent}}"))

            XCTAssertLessThan(prior.lowerBound, intent.lowerBound, path)
            XCTAssertFalse(template.contains("conversation history"), path)
            XCTAssertFalse(template.contains("conversationSeed"), path)
        }
    }
}
