import XCTest
@testable import Gravitas_Plague

@MainActor
final class TuringEpisodeFlowReplayTests:
    XCTestCase {

    func testCompletedPointDoesNotReplayImplicitly()
        async throws {
        let pointID = "test.replay.point"
        let characterID = "fixture"
        let voiceID = "fixture_voice"
        let prerecordingID =
            "\(pointID).pr"
        let promptID =
            "\(pointID).prompt"
        let routeID =
            TuringVoiceOutputContext(
                rawValue: "fixtureRoute"
            )
        let conversationKey =
            "fixture.thread"

        let recorder =
            TuringFlowTestEventRecorder()
        let route =
            StubFlowRoute(
                outputRoute: routeID,
                recorder: recorder,
                autoCompletePrerecording:
                    true
            )
        let descriptor =
            TuringFlowTestFixtures.descriptor(
                id: pointID,
                prerecordingID:
                    prerecordingID,
                voicePromptID:
                    promptID,
                characterID:
                    characterID,
                outputRoute:
                    routeID,
                conversationKey:
                    conversationKey
            )
        let prerecording =
            TuringFlowTestFixtures
                .prerecording(
                    id:
                        prerecordingID,
                    characterID:
                        characterID,
                    voiceID:
                        voiceID
                )
        let prompt =
            TuringFlowTestFixtures.prompt(
                id: promptID,
                characterID:
                    characterID,
                voiceID: voiceID,
                outputRoute:
                    routeID,
                conversationKey:
                    conversationKey
            )
        let character =
            TuringFlowTestFixtures.character(
                id: characterID,
                voiceID: voiceID,
                outputRoute: routeID
            )
        let descriptorStore =
            StubFlowDescriptorStore(
                descriptors: [
                    pointID:
                        descriptor
                ]
            )
        let seedStore =
            TuringConversationSeedStore()
        let historyStore =
            TuringDialogueHistoryStore()
        let engine =
            TuringFlowEngine(
                descriptorStore:
                    descriptorStore,
                prerecordingStore:
                    StubPrerecordingStore(
                        descriptors: [
                            prerecordingID:
                                prerecording
                        ]
                    ),
                voicePromptStore:
                    StubVoicePromptStore(
                        descriptors: [
                            promptID:
                                prompt
                        ]
                    ),
                characterRuntimeStore:
                    StubCharacterRuntimeStore(
                        definitions: [
                            characterID:
                                character
                        ]
                    ),
                dialogueService:
                    ControlledVoicePromptService(
                        recorder: recorder,
                        behavior: .immediate(
                            TuringFlowTestFixtures
                                .plan
                        )
                    ),
                routeResolver:
                    StubFlowRouteResolver(
                        route: route
                    ),
                rendererFactory:
                    StubCharacterRendererFactory(
                        recorder: recorder,
                        completionOrder: [
                            0,
                            1
                        ],
                        failureMessage: nil
                ),
                seedStore: seedStore,
                historyStore:
                    historyStore
            )
        let episode =
            TuringEpisodeFlowController(
                engine: engine,
                descriptorStore:
                    descriptorStore,
                seedStore: seedStore,
                historyStore:
                    historyStore,
                catalogValidator: nil
            )

        let first = await episode.start(
            scriptPointID: pointID,
            trigger: .manualDebug
        )
        XCTAssertTrue(
            first.succeeded,
            first.pickerStatus
        )

        let eventsAfterFirst =
            await recorder.snapshot()
        let firstPRStartCount =
            eventsAfterFirst.filter {
                $0 == "pr.started"
            }.count
        XCTAssertEqual(
            firstPRStartCount,
            1
        )

        let second = await episode.start(
            scriptPointID: pointID,
            trigger: .manualDebug
        )
        XCTAssertFalse(
            second.succeeded
        )

        let eventsAfterSecond =
            await recorder.snapshot()
        let secondPRStartCount =
            eventsAfterSecond.filter {
                $0 == "pr.started"
            }.count
        XCTAssertEqual(
            secondPRStartCount,
            1
        )
    }
}
