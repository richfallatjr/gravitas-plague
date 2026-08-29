import Foundation
import XCTest

@testable import Gravitas_Plague

@MainActor
final class TuringBroadcasterCrankRadioResourceTests: XCTestCase {
    private let scriptPointID =
        "prologue.crankRadioBroadcast.001"
    private let prerecordingID =
        "prologue.room.broadcaster.crankRadio.001"
    private let voicePromptID =
        "prologue.broadcaster.crankRadio.followUp.001"

    func testDescriptorUsesSharedBroadcasterPipeline() throws {
        let descriptor = try TuringFlowDescriptorStore()
            .require(scriptPointID)

        XCTAssertEqual(
            descriptor.transmission.characterID,
            "broadcaster"
        )
        XCTAssertEqual(
            descriptor.transmission.outputRoute,
            .crankRadioSpatial
        )
        XCTAssertEqual(
            descriptor.transmission.effectiveInteractionSurface,
            .crankRadio
        )
        XCTAssertEqual(
            descriptor.transmission.computeStart,
            .foundationBeforePrerecording
        )
        XCTAssertEqual(
            descriptor.transmission.fillerMode,
            .none
        )
        XCTAssertFalse(
            descriptor.transmission.commSFX
                .openBeforePrerecording
        )
        XCTAssertFalse(
            descriptor.transmission.commSFX
                .sendAfterGenerated
        )
        XCTAssertEqual(
            descriptor.progression
                .interactionGateAfterCompletion,
            .microphone
        )
    }

    func testBroadcasterRuntimeAllowsOnlyCrankRadioSpatial() throws {
        let runtime = try TuringCharacterRuntimeRegistry()
            .require("broadcaster")

        XCTAssertEqual(
            runtime.voiceID,
            "broadcaster_base_clone_v1"
        )
        XCTAssertEqual(
            runtime.allowedOutputRoutes,
            [.crankRadioSpatial]
        )
        XCTAssertEqual(
            runtime.outputProcessing.playbackRate,
            0.85,
            accuracy: 0.0001
        )
        XCTAssertTrue(
            runtime.audio.fillerDirectoryCandidates.isEmpty
        )
        XCTAssertTrue(runtime.audio.fillerExtensions.isEmpty)
    }

    func testPromptAndPrerecordingIdentityMatch() throws {
        let prerecording = try TuringPrerecordingStore()
            .descriptor(id: prerecordingID)
        let prompt = try TuringVoicePromptTriggerStore()
            .descriptor(id: voicePromptID)

        XCTAssertEqual(
            prerecording.voiceID,
            "broadcaster_base_clone_v1"
        )
        XCTAssertEqual(prompt.speakerID, "broadcaster")
        XCTAssertEqual(
            prompt.voiceID,
            prerecording.voiceID
        )
        XCTAssertEqual(
            prompt.outputContext,
            .crankRadioSpatial
        )
        XCTAssertEqual(
            prompt.conversationKey,
            "object.crank_radio"
        )
        XCTAssertEqual(
            prompt.effectivePromptTemplateID,
            .broadcasterRadio
        )
    }

    func testBroadcasterPRIsByteIdenticalToEmergencyBroadcast()
        throws
    {
        let source = try TuringResourceLoader.resourceURL(
            resourcePath:
                "Turing/Audio/rolling-bench/EmergencyBroadcast.mp3"
        )
        let installed = try TuringResourceLoader.resourceURL(
            resourcePath:
                "Turing/Audio/prerecordings/pr-broadcaster-emergency-broadcast.mp3"
        )

        XCTAssertEqual(
            try Data(contentsOf: source),
            try Data(contentsOf: installed)
        )
    }

    func testAmbientStaticRemainsIndependentFromTuningLoop()
        async throws
    {
        let endpoint =
            BroadcasterRadioBedTestEndpoint()
        let radioBed =
            TuringRollingBenchRadioBedActor()
        let tuningLoops =
            TuringCrankRadioTuningLoopActor(
                randomIndex: { _ in 0 }
            )

        try await radioBed.prepareResources()
        try await tuningLoops.prepareResources()
        await radioBed.install(endpoint: endpoint)
        await tuningLoops.install(endpoint: endpoint)

        try await radioBed.beginSession(
            ownerID: "broadcaster-test"
        )
        await tuningLoops.beginGap(
            ownerID: "broadcaster-test",
            waitingForSegmentIndex: 0,
            reason: "testFoundationGap"
        )

        var snapshot = await endpoint.snapshot()
        XCTAssertEqual(snapshot.played.count, 2)
        let ambient = try XCTUnwrap(
            snapshot.played.first {
                $0.kind == .ambientStatic
            }
        )
        let tuning = try XCTUnwrap(
            snapshot.played.first {
                $0.kind ==
                    .crankRadioTuningFiller
            }
        )
        XCTAssertEqual(
            ambient.fileURL.lastPathComponent,
            "Narrow-band-analog.wav"
        )
        XCTAssertEqual(
            ambient.route,
            .rollingBenchRadio
        )
        XCTAssertEqual(ambient.gainDB, -15)
        XCTAssertTrue(ambient.shouldLoop)
        XCTAssertEqual(
            ambient.cachePolicy,
            .bundled
        )
        XCTAssertNotEqual(
            ambient.requestID,
            tuning.requestID
        )

        await tuningLoops.endGap(
            ownerID: "broadcaster-test",
            reason: "exactSegmentReady"
        )
        snapshot = await endpoint.snapshot()
        XCTAssertEqual(snapshot.stopped.count, 1)

        await radioBed.endSession(
            ownerID: "broadcaster-test",
            reason: "testFinished"
        )
        snapshot = await endpoint.snapshot()
        XCTAssertEqual(snapshot.stopped.count, 2)
    }

    func testClonePackageIsPrecomputedAndRuntimeEncodingIsDisabled()
        throws
    {
        let root = try TuringResourceLoader.resourceURL(
            resourcePath:
                "Turing/Voices/Cloned/Broadcaster/BaseClone/broadcaster_base_clone_v1.qwenclone/metadata.json"
        )
        let profileRoot = root.deletingLastPathComponent()
        let metadata = try jsonObject(root)
        let variant = try jsonObject(
            profileRoot.appendingPathComponent(
                "variants/broadcaster_reference_fast_01/variant.json"
            )
        )
        let artifacts = try XCTUnwrap(
            variant["qwenArtifacts"] as? [String: Any]
        )

        XCTAssertEqual(
            metadata["allowRuntimeRefAudioEncoding"] as? Bool,
            false
        )
        XCTAssertEqual(
            artifacts["status"] as? String,
            "precomputed"
        )
        for path in [
            "clone_artifacts.safetensors",
            "reference_codes.i32le",
            "ref_text_tokens.i32le",
            "speaker_embedding.f32le"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath:
                        profileRoot
                        .appendingPathComponent(
                            "variants/broadcaster_reference_fast_01/qwen_artifacts/\(path)"
                        )
                        .path
                ),
                "Missing precomputed Broadcaster artifact \(path)."
            )
        }
    }

    func testPromptVoiceRendersExactIsolatedInputs() async throws {
        let runner = BroadcasterPromptCapturingRunner()
        let service = TuringDialogueService(runner: runner)
        let profile = try TuringCharacterProfileStore()
            .profile(id: "broadcaster")
        let prerecording = try TuringPrerecordingStore()
            .descriptor(id: prerecordingID)
        let descriptor = try TuringVoicePromptTriggerStore()
            .descriptor(id: voicePromptID)

        _ = try await service.generateVoicePrompt(
            VoicePromptRequest(
                id: voicePromptID,
                characterProfileID:
                    descriptor.characterProfileID,
                listenerProfileID:
                    descriptor.listenerProfileID,
                promptContext:
                    descriptor.effectiveAuthoredStoryContext,
                prerecordingTranscript:
                    prerecording.transcript,
                storyIntent:
                    descriptor.effectiveAuthoredStoryContext,
                promptTemplateID:
                    descriptor.effectivePromptTemplateID
            )
        )

        let capturedPrompt = runner.lastPrompt()
        let prompt = try XCTUnwrap(capturedPrompt)
        XCTAssertEqual(
            occurrenceCount(profile.writeup, in: prompt),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                descriptor.effectiveAuthoredStoryContext,
                in: prompt
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(prerecording.transcript, in: prompt),
            1
        )
        XCTAssertFalse(prompt.contains("HOW RICH RESPONDS"))
        XCTAssertFalse(prompt.contains("dialogue history"))
    }

    func testConversationRendersExactHistoryFreeInputs() async throws {
        let runner = BroadcasterPromptCapturingRunner()
        let service = TuringDialogueService(runner: runner)
        let profile = try TuringCharacterProfileStore()
            .profile(id: "broadcaster")
        let prerecording = try TuringPrerecordingStore()
            .descriptor(id: prerecordingID)
        let descriptor = try TuringVoicePromptTriggerStore()
            .descriptor(id: voicePromptID)
        let playerStatement =
            "Is there verified guidance about travel?"

        _ = try await service.generateConversationNoBible(
            ConversationPromptNoBibleRequest(
                id: "test.broadcaster.conversation",
                characterProfileID: "broadcaster",
                userInput: playerStatement,
                promptContext:
                    descriptor.effectiveAuthoredStoryContext,
                prerecordingTranscript:
                    prerecording.transcript,
                promptVariant: .broadcasterRadio
            )
        )

        let capturedPrompt = runner.lastPrompt()
        let prompt = try XCTUnwrap(capturedPrompt)
        XCTAssertEqual(
            occurrenceCount(profile.writeup, in: prompt),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                descriptor.effectiveAuthoredStoryContext,
                in: prompt
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(prerecording.transcript, in: prompt),
            1
        )
        XCTAssertEqual(
            occurrenceCount(playerStatement, in: prompt),
            1
        )
        XCTAssertFalse(prompt.contains("dialogue history"))
        XCTAssertFalse(prompt.contains("You are Big Mike"))
        XCTAssertFalse(prompt.contains("You are Rich"))
    }

    private func jsonObject(
        _ url: URL
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
    }

    private func occurrenceCount(
        _ needle: String,
        in haystack: String
    ) -> Int {
        guard needle.isEmpty == false else {
            return 0
        }
        return haystack.components(separatedBy: needle).count - 1
    }
}

@MainActor
private final class BroadcasterPromptCapturingRunner:
    TuringFoundationQueryRunning,
    @unchecked Sendable
{
    private var prompt: String?

    func runPrompt(
        _ prompt: String,
        purpose _: String
    ) async throws -> String {
        self.prompt = prompt
        return """
        {
          "schemaVersion": 1,
          "segments": [
            {
              "text": "Additional verified guidance will follow.",
              "emotion": "measured and formal"
            }
          ]
        }
        """
    }

    func lastPrompt() -> String? {
        prompt
    }
}

private actor BroadcasterRadioBedTestEndpoint:
    TuringTransientAudioPlaybackEndpoint
{
    struct Snapshot: Sendable {
        let played: [TuringAudioPlaybackRequest]
        let stopped: [TuringAudioPlaybackHandle]
    }

    private let eventHub =
        TuringAudioEventHub()
    private var played:
        [TuringAudioPlaybackRequest] = []
    private var stopped:
        [TuringAudioPlaybackHandle] = []

    func play(
        _ request: TuringAudioPlaybackRequest
    ) async throws -> TuringAudioPlaybackHandle {
        played.append(request)
        let handle =
            TuringAudioPlaybackHandle(
                id: UUID(),
                requestID: request.requestID,
                runID: request.runID,
                route: request.route
            )
        await eventHub.yield(
            .started(handle: handle, clockOrigin: ContinuousClock.now)
        )
        return handle
    }

    func stop(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async {
        stopped.append(handle)
        await eventHub.yield(
            .cancelled(
                handle,
                reason: reason
            )
        )
    }

    func events() async
        -> AsyncStream<TuringAudioPlaybackEvent>
    {
        await eventHub.stream()
    }

    func evictTransient(fileURL _: URL) async {
    }

    func snapshot() -> Snapshot {
        Snapshot(
            played: played,
            stopped: stopped
        )
    }
}
