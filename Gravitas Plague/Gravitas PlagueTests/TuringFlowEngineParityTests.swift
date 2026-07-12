import XCTest
@testable import Gravitas_Plague

@MainActor
final class TuringFlowEngineParityTests:
    XCTestCase {

    override func setUp() async throws {
        await TuringFlowInteractionGateController
            .shared
            .reset(reason: "unitTest")
    }

    func testOutOfOrderFresh2PublicationWaitsForPRAndPlaysInOrder()
        async throws {
        let harness = try makeHarness(
            behavior: .immediate(
                TuringFlowTestFixtures.plan
            ),
            completionOrder: [1, 0],
            open: true,
            send: true
        )

        let runTask = Task {
            await harness.engine.run(
                scriptPointID:
                    harness.scriptPointID,
                trigger: .manualDebug
            )
        }

        try await harness.recorder.waitFor(
            "playback.segment.1.published"
        )
        try await harness.recorder.waitFor(
            "playback.segment.0.published"
        )

        let beforePR =
            await harness.recorder.snapshot()

        XCTAssertFalse(
            beforePR.contains(
                "generated.0.started"
            )
        )
        XCTAssertFalse(
            beforePR.contains(
                "generated.1.started"
            )
        )
        XCTAssertTrue(
            beforePR.contains(
                "foundation.started"
            )
        )

        guard let playback =
                harness.route.latestPlayback else {
            XCTFail("Missing fake playback")
            return
        }

        await playback.completePrerecording()

        let result = await runTask.value
        XCTAssertTrue(
            result.succeeded,
            result.message
        )

        let events =
            await harness.recorder.snapshot()

        assertOrder(
            events,
            [
                "route.open",
                "playback.begin",
                "pr.enqueued",
                "pr.started",
                "qwen.segment.1.finished",
                "qwen.segment.0.finished",
                "pr.completed",
                "generated.0.started",
                "generated.0.completed",
                "generated.1.started",
                "generated.1.completed",
                "playback.finished",
                "route.send",
                "route.finish.true"
            ]
        )

        XCTAssertEqual(
            result.expectedGeneratedSegmentCount,
            2
        )
        XCTAssertEqual(
            result.completedGeneratedSegmentCount,
            2
        )
        XCTAssertEqual(
            TuringFlowInteractionGateController
                .shared.state,
            .microphone
        )
    }

    func testLateSegmentZeroUsesFillerAfterPRAndBeforeGeneratedSpeech()
        async throws {
        let recorder =
            TuringFlowTestEventRecorder()
        let service =
            ControlledVoicePromptService(
                recorder: recorder,
                behavior: .delayed(
                    TuringFlowTestFixtures.plan
                )
            )

        let harness = try makeHarness(
            recorder: recorder,
            dialogueService: service,
            completionOrder: [0, 1],
            open: false,
            send: false
        )

        let runTask = Task {
            await harness.engine.run(
                scriptPointID:
                    harness.scriptPointID,
                trigger: .manualDebug
            )
        }

        try await recorder.waitFor(
            "pr.started"
        )

        guard let playback =
                harness.route.latestPlayback else {
            XCTFail("Missing fake playback")
            return
        }

        await playback.completePrerecording()
        try await recorder.waitFor(
            "filler.completed"
        )

        await service.release()

        let result = await runTask.value
        XCTAssertTrue(
            result.succeeded,
            result.message
        )

        let events =
            await recorder.snapshot()
        assertOrder(
            events,
            [
                "pr.started",
                "pr.completed",
                "filler.started",
                "filler.completed",
                "foundation.completed",
                "generated.0.started",
                "generated.0.completed"
            ]
        )
    }

    func testFoundationFailurePreservesActivePR()
        async throws {
        let harness = try makeHarness(
            behavior: .failed(
                "Foundation fixture failure"
            ),
            completionOrder: [],
            open: false,
            send: false
        )

        let runTask = Task {
            await harness.engine.run(
                scriptPointID:
                    harness.scriptPointID,
                trigger: .manualDebug
            )
        }

        try await harness.recorder.waitFor(
            "pr.started"
        )

        guard let playback =
                harness.route.latestPlayback else {
            XCTFail("Missing fake playback")
            return
        }

        let beforeCompletion =
            await harness.recorder.snapshot()

        XCTAssertFalse(
            beforeCompletion.contains(
                "playback.cancelled"
            )
        )

        await playback.completePrerecording()
        let result = await runTask.value

        XCTAssertEqual(
            result.outcome,
            .generatedPlanFailed
        )

        let events =
            await harness.recorder.snapshot()

        XCTAssertTrue(
            events.contains("pr.completed")
        )
        XCTAssertFalse(
            events.contains(
                "playback.cancelled"
            )
        )
    }

    func testQwenFailurePreservesActivePRAndTerminatesWaiter()
        async throws {
        let harness = try makeHarness(
            behavior: .immediate(
                TuringFlowTestFixtures.plan
            ),
            completionOrder: [],
            rendererFailure:
                "Qwen fixture failure",
            open: false,
            send: false
        )

        let runTask = Task {
            await harness.engine.run(
                scriptPointID:
                    harness.scriptPointID,
                trigger: .manualDebug
            )
        }

        try await harness.recorder.waitFor(
            "playback.compute.failed"
        )

        guard let playback =
                harness.route.latestPlayback else {
            XCTFail("Missing fake playback")
            return
        }

        await playback.completePrerecording()
        let result = await runTask.value

        XCTAssertEqual(
            result.outcome,
            .generatedAudioFailed
        )

        let events =
            await harness.recorder.snapshot()

        XCTAssertTrue(
            events.contains(
                "playback.finished"
            )
        )
        XCTAssertFalse(
            events.contains(
                "playback.cancelled"
            )
        )
    }

    func testPoint01Point02Point03ShareOneEngineLifecycle()
        async throws {
        for point in [
            "prologue.scriptPoint01",
            "prologue.scriptPoint02",
            "prologue.scriptPoint03"
        ] {
            let harness = try makeHarness(
                scriptPointID: point,
                behavior: .immediate(
                    TuringFlowTestFixtures.plan
                ),
                completionOrder: [0, 1],
                open:
                    point ==
                    "prologue.scriptPoint02",
                send:
                    point ==
                    "prologue.scriptPoint02",
                fixedLeadIn:
                    point ==
                    "prologue.scriptPoint03"
                    ? 10
                    : nil,
                autoCompletePrerecording:
                    true
            )

            let result = await harness.engine.run(
                scriptPointID: point,
                trigger: .manualDebug
            )

            XCTAssertTrue(
                result.succeeded,
                "\(point): \(result.message)"
            )

            let events =
                await harness.recorder.snapshot()

            assertOrder(
                events,
                [
                    "playback.begin",
                    "pr.enqueued",
                    "pr.started",
                    "pr.completed",
                    "qwen.started",
                    "generated.0.started",
                    "generated.0.completed",
                    "generated.1.started",
                    "generated.1.completed",
                    "playback.finished",
                    "route.finish.true"
                ]
            )
        }
    }

    private struct Harness {
        let scriptPointID: String
        let recorder:
            TuringFlowTestEventRecorder
        let route: StubFlowRoute
        let engine: TuringFlowEngine
    }

    private func makeHarness(
        scriptPointID: String =
            "test.scriptPoint",
        behavior:
            ControlledVoicePromptService.Behavior,
        completionOrder: [Int],
        rendererFailure: String? = nil,
        open: Bool,
        send: Bool,
        fixedLeadIn: Double? = nil,
        autoCompletePrerecording: Bool =
            false
    ) throws -> Harness {
        let recorder =
            TuringFlowTestEventRecorder()
        let service =
            ControlledVoicePromptService(
                recorder: recorder,
                behavior: behavior
            )

        return try makeHarness(
            scriptPointID:
                scriptPointID,
            recorder: recorder,
            dialogueService: service,
            completionOrder:
                completionOrder,
            rendererFailure:
                rendererFailure,
            open: open,
            send: send,
            fixedLeadIn:
                fixedLeadIn,
            autoCompletePrerecording:
                autoCompletePrerecording
        )
    }

    private func makeHarness(
        scriptPointID: String =
            "test.scriptPoint",
        recorder:
            TuringFlowTestEventRecorder,
        dialogueService:
            ControlledVoicePromptService,
        completionOrder: [Int],
        rendererFailure: String? = nil,
        open: Bool,
        send: Bool,
        fixedLeadIn: Double? = nil,
        autoCompletePrerecording: Bool =
            false
    ) throws -> Harness {
        let characterID = "fixture"
        let voiceID = "fixture_voice"
        let prerecordingID =
            "\(scriptPointID).pr"
        let voicePromptID =
            "\(scriptPointID).prompt"
        let routeID =
            TuringVoiceOutputContext(
                rawValue: "fixtureRoute"
            )
        let conversationKey =
            "fixture.conversation"

        let descriptor =
            TuringFlowTestFixtures.descriptor(
                id: scriptPointID,
                prerecordingID:
                    prerecordingID,
                voicePromptID:
                    voicePromptID,
                characterID:
                    characterID,
                outputRoute:
                    routeID,
                conversationKey:
                    conversationKey,
                open: open,
                send: send,
                fixedLeadIn:
                    fixedLeadIn
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
                id: voicePromptID,
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
        let route = StubFlowRoute(
            outputRoute: routeID,
            recorder: recorder,
            autoCompletePrerecording:
                autoCompletePrerecording
        )

        let engine = TuringFlowEngine(
            descriptorStore:
                StubFlowDescriptorStore(
                    descriptors: [
                        scriptPointID:
                            descriptor
                    ]
                ),
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
                        voicePromptID:
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
                dialogueService,
            routeResolver:
                StubFlowRouteResolver(
                    route: route
                ),
            rendererFactory:
                StubCharacterRendererFactory(
                    recorder: recorder,
                    completionOrder:
                        completionOrder,
                    failureMessage:
                        rendererFailure
                ),
            seedStore:
                TuringConversationSeedStore(),
            historyStore:
                TuringDialogueHistoryStore()
        )

        return Harness(
            scriptPointID:
                scriptPointID,
            recorder: recorder,
            route: route,
            engine: engine
        )
    }

    private func assertOrder(
        _ events: [String],
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = 0

        for event in expected {
            guard let index =
                events[cursor...]
                    .firstIndex(
                        of: event
                    ) else {
                XCTFail(
                    "Missing ordered event \(event). Events: \(events)",
                    file: file,
                    line: line
                )
                return
            }
            cursor = events.index(
                after: index
            )
        }
    }
}
