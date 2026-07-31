import CryptoKit
import Foundation
import XCTest

@testable import Gravitas_Plague

@MainActor
final class TuringHamReceiverThreePointFlowTests:
    XCTestCase
{
    private let scriptPointIDs = [
        "prologue.hamReceiver.cateye81.001",
        "prologue.hamReceiver.rich.002",
        "prologue.hamReceiver.cateye81.003"
    ]

    private let prerecordingIDs = [
        "prologue.room.cateye81.hamReceiver.001",
        "prologue.room.rich.hamReceiver.002",
        "prologue.room.cateye81.hamReceiver.003"
    ]

    private let voicePromptIDs = [
        "prologue.cateye81.hamReceiver.followUp.001",
        "prologue.rich.hamReceiver.followUp.002",
        "prologue.cateye81.hamReceiver.followUp.003"
    ]

    func testThreePointDescriptorsFormOneAutomaticChain()
        throws
    {
        let descriptors = try scriptPointIDs.map {
            try TuringFlowDescriptorStore().require($0)
        }

        XCTAssertEqual(
            descriptors.map(\.scriptPointID),
            scriptPointIDs
        )
        XCTAssertEqual(
            descriptors.map {
                $0.transmission.prerecordingID
            },
            prerecordingIDs
        )
        XCTAssertEqual(
            descriptors.compactMap {
                $0.transmission.voicePromptID
            },
            voicePromptIDs
        )
        XCTAssertEqual(
            descriptors.map {
                $0.transmission.characterID
            },
            ["cateye81", "rich", "cateye81"]
        )
        XCTAssertEqual(
            descriptors.map {
                $0.transmission.outputRoute
            },
            [
                .hamReceiverSpatial,
                .roomGlobal,
                .hamReceiverSpatial
            ]
        )

        for descriptor in descriptors {
            XCTAssertEqual(
                descriptor.transmission
                    .conversationKey,
                "object.ham_receiver"
            )
            XCTAssertEqual(
                descriptor.transmission
                    .effectiveInteractionSurface,
                .hamReceiver
            )
            XCTAssertEqual(
                descriptor.transmission.computeStart,
                .foundationBeforePrerecording
            )
            XCTAssertFalse(
                descriptor.transmission.commSFX
                    .openBeforePrerecording
            )
            XCTAssertFalse(
                descriptor.transmission.commSFX
                    .sendAfterGenerated
            )
        }

        XCTAssertEqual(
            descriptors[0].trigger.kind,
            .userPlay
        )
        XCTAssertEqual(
            descriptors[0].progression
                .nextScriptPointID,
            scriptPointIDs[1]
        )
        XCTAssertTrue(
            descriptors[0].progression
                .automaticAdvance
        )
        XCTAssertEqual(
            descriptors[0].progression
                .interactionGateAfterCompletion,
            .closed
        )

        XCTAssertEqual(
            descriptors[1].trigger.kind,
            .priorScriptPointCompleted
        )
        XCTAssertEqual(
            descriptors[1].transmission.fillerMode,
            .continuousFromPrerecordingToGenerated
        )
        XCTAssertEqual(
            descriptors[1].progression
                .nextScriptPointID,
            scriptPointIDs[2]
        )
        XCTAssertTrue(
            descriptors[1].progression
                .automaticAdvance
        )
        XCTAssertEqual(
            descriptors[1].progression
                .interactionGateAfterCompletion,
            .closed
        )

        XCTAssertEqual(
            descriptors[2].trigger.kind,
            .priorScriptPointCompleted
        )
        XCTAssertEqual(
            descriptors[2].transmission.fillerMode,
            .none
        )
        XCTAssertNil(
            descriptors[2].progression
                .nextScriptPointID
        )
        XCTAssertFalse(
            descriptors[2].progression
                .automaticAdvance
        )
        XCTAssertEqual(
            descriptors[2].progression
                .interactionGateAfterCompletion,
            .microphone
        )
    }

    func testNewPrerecordingsMatchApprovedFiles()
        throws
    {
        let expectedHashes = [
            "prologue.room.rich.hamReceiver.002":
                "4eb04a0656565f1ecc724f13fac847d4f3c3a98bf01302f92a52ed87dd06359d",
            "prologue.room.cateye81.hamReceiver.003":
                "621b8da451b233e182cde4dd6a04fdbb84e578969146d56cf44a4c607a9390d2"
        ]

        for (prerecordingID, expectedHash)
            in expectedHashes {
            let descriptor =
                try TuringPrerecordingStore()
                    .descriptor(
                        id: prerecordingID
                    )
            XCTAssertFalse(
                descriptor.transcript
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .isEmpty
            )
            let url =
                try TuringResourceLoader
                    .resourceURL(
                        resourcePath:
                            "Turing/Audio/prerecordings/\(descriptor.audioFile)"
                    )
            XCTAssertEqual(
                try sha256(url),
                expectedHash
            )
        }
    }

    func testPromptDescriptorsUseExactSurfaceIdentity()
        throws
    {
        let prompts = try voicePromptIDs.map {
            try TuringVoicePromptTriggerStore()
                .descriptor(id: $0)
        }

        XCTAssertEqual(
            prompts.map(\.conversationKey),
            Array(
                repeating: "object.ham_receiver",
                count: 3
            )
        )
        XCTAssertEqual(
            prompts.map(\.speakerID),
            ["cateye81", "rich", "cateye81"]
        )
        XCTAssertEqual(
            prompts.map(\.effectivePromptTemplateID),
            [
                .cateye81HamReceiver,
                .richHamReceiver,
                .cateye81HamReceiver
            ]
        )
        XCTAssertEqual(
            prompts.map(\.outputContext),
            [
                .hamReceiverSpatial,
                .roomGlobal,
                .hamReceiverSpatial
            ]
        )
    }

    func testPromptVoiceInputsRemainPointLocal()
        async throws
    {
        let runner =
            HamReceiverPromptCapturingRunner()
        let service =
            TuringDialogueService(
                runner: runner
            )
        let prerecordingStore =
            TuringPrerecordingStore()
        let promptStore =
            TuringVoicePromptTriggerStore()

        let script01PR =
            try prerecordingStore.descriptor(
                id: prerecordingIDs[0]
            )
        let script02PR =
            try prerecordingStore.descriptor(
                id: prerecordingIDs[1]
            )
        let script03PR =
            try prerecordingStore.descriptor(
                id: prerecordingIDs[2]
            )
        let script02 =
            try promptStore.descriptor(
                id: voicePromptIDs[1]
            )
        let script03 =
            try promptStore.descriptor(
                id: voicePromptIDs[2]
            )

        _ = try await generatePromptVoice(
            service: service,
            descriptor: script02,
            prerecording: script02PR
        )
        let capturedRichPrompt =
            await runner.lastPrompt()
        let richPrompt =
            try XCTUnwrap(capturedRichPrompt)
        let richProfile =
            try TuringCharacterProfileStore()
                .profile(id: "rich")
        XCTAssertEqual(
            occurrenceCount(
                richProfile.writeup,
                in: richPrompt
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                script02.effectiveAuthoredStoryContext,
                in: richPrompt
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                script02PR.transcript,
                in: richPrompt
            ),
            1
        )
        XCTAssertFalse(
            richPrompt.contains(
                script01PR.transcript
            )
        )

        _ = try await generatePromptVoice(
            service: service,
            descriptor: script03,
            prerecording: script03PR
        )
        let capturedCatEyePrompt =
            await runner.lastPrompt()
        let catEyePrompt =
            try XCTUnwrap(capturedCatEyePrompt)
        let catEyeProfile =
            try TuringCharacterProfileStore()
                .profile(
                    id: "cateye81.prologue"
                )
        XCTAssertEqual(
            occurrenceCount(
                catEyeProfile.writeup,
                in: catEyePrompt
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                script03.effectiveAuthoredStoryContext,
                in: catEyePrompt
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                script03PR.transcript,
                in: catEyePrompt
            ),
            1
        )
        XCTAssertFalse(
            catEyePrompt.contains(
                script02PR.transcript
            )
        )
        XCTAssertFalse(
            catEyePrompt.contains(
                script02.effectiveAuthoredStoryContext
            )
        )
    }

    func testFinalConversationContainsOnlyScript03Seed()
        async throws
    {
        let runner =
            HamReceiverPromptCapturingRunner()
        let service =
            TuringDialogueService(
                runner: runner
            )
        let prerecordingStore =
            TuringPrerecordingStore()
        let promptStore =
            TuringVoicePromptTriggerStore()
        let script01 =
            try promptStore.descriptor(
                id: voicePromptIDs[0]
            )
        let script02 =
            try promptStore.descriptor(
                id: voicePromptIDs[1]
            )
        let script03 =
            try promptStore.descriptor(
                id: voicePromptIDs[2]
            )
        let script01PR =
            try prerecordingStore.descriptor(
                id: prerecordingIDs[0]
            )
        let script02PR =
            try prerecordingStore.descriptor(
                id: prerecordingIDs[1]
            )
        let script03PR =
            try prerecordingStore.descriptor(
                id: prerecordingIDs[2]
            )
        let playerStatement =
            "Repeat the Channel One frequency."

        _ = try await service.generateConversationNoBible(
            ConversationPromptNoBibleRequest(
                id:
                    "test.hamReceiver.script03.conversation",
                characterProfileID:
                    script03.characterProfileID,
                userInput: playerStatement,
                promptContext:
                    script03.effectiveAuthoredStoryContext,
                prerecordingTranscript:
                    script03PR.transcript,
                promptVariant:
                    .cateye81HamReceiver
            )
        )

        let capturedPrompt =
            await runner.lastPrompt()
        let prompt =
            try XCTUnwrap(capturedPrompt)
        XCTAssertEqual(
            occurrenceCount(
                script03.effectiveAuthoredStoryContext,
                in: prompt
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                script03PR.transcript,
                in: prompt
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                playerStatement,
                in: prompt
            ),
            1
        )
        XCTAssertFalse(
            prompt.contains(
                script01.effectiveAuthoredStoryContext
            )
        )
        XCTAssertFalse(
            prompt.contains(
                script01PR.transcript
            )
        )
        XCTAssertFalse(
            prompt.contains(
                script02.effectiveAuthoredStoryContext
            )
        )
        XCTAssertFalse(
            prompt.contains(
                script02PR.transcript
            )
        )
    }

    func testOneAmbientOwnerSpansAllThreePoints()
        async throws
    {
        let bed = HamReceiverBedSpy()
        let lifecycle =
            TuringHamReceiverSequenceLifecycle(
                bed: bed
            )
        let descriptors = try scriptPointIDs.map {
            try TuringFlowDescriptorStore().require($0)
        }
        let sequenceID = UUID()

        try await lifecycle.begin(
            sequenceID: sequenceID,
            initialDescriptor:
                descriptors[0]
        )

        for (index, descriptor)
            in descriptors.enumerated() {
            try await lifecycle.pointWillBegin(
                sequenceID: sequenceID,
                descriptor: descriptor
            )
            await lifecycle.pointDidFinish(
                sequenceID: sequenceID,
                descriptor: descriptor,
                succeeded: true,
                hasAutomaticSuccessor:
                    index < descriptors.count - 1
            )
            let snapshot =
                await bed.snapshot()
            XCTAssertEqual(
                snapshot.beginOwnerIDs.count,
                1
            )
            XCTAssertTrue(
                snapshot.endOwnerIDs.isEmpty
            )
        }

        await lifecycle.end(
            sequenceID: sequenceID,
            finalDescriptor:
                descriptors[2],
            succeeded: true,
            reason: "testCompleted"
        )

        let snapshot =
            await bed.snapshot()
        XCTAssertEqual(
            snapshot.beginOwnerIDs.count,
            1
        )
        XCTAssertEqual(
            snapshot.endOwnerIDs,
            snapshot.beginOwnerIDs
        )
    }

    func testRichScript02UsesTuningOnlyBeforePrerecording()
        async throws
    {
        let tuning = HamReceiverTuningSpy()
        let route = TuringRichRoomFlowRoute(
            hamReceiverTuningLoops: tuning
        )
        let descriptor =
            try TuringFlowDescriptorStore()
                .require(scriptPointIDs[1])
        let identity = TuringFlowIdentity(
            scriptPointID:
                descriptor.scriptPointID,
            characterID:
                descriptor.transmission.characterID,
            prerecordingID:
                descriptor.transmission.prerecordingID,
            voicePromptID:
                try XCTUnwrap(
                    descriptor.transmission.voicePromptID
                ),
            interactionSurface: .hamReceiver,
            playbackRunID:
                "test.hamReceiver.rich.002"
        )

        try await route.playOpenIfNeeded(
            descriptor: descriptor,
            identity: identity
        )
        var snapshot = await tuning.snapshot()
        XCTAssertEqual(snapshot.begins.count, 1)
        XCTAssertEqual(
            snapshot.begins.first?.ownerID,
            identity.playbackRunID
        )
        XCTAssertEqual(
            snapshot.begins.first?
                .waitingForSegmentIndex,
            0
        )
        XCTAssertTrue(snapshot.ends.isEmpty)

        try await route
            .beginPrerecordingLeadInIfNeeded(
                descriptor: descriptor,
                identity: identity
            )
        snapshot = await tuning.snapshot()
        XCTAssertEqual(snapshot.ends.count, 1)
        XCTAssertEqual(
            snapshot.ends.first?.ownerID,
            identity.playbackRunID
        )

        await route.finish(
            descriptor: descriptor,
            identity: identity,
            succeeded: true
        )
        snapshot = await tuning.snapshot()
        XCTAssertEqual(snapshot.begins.count, 1)
        XCTAssertEqual(snapshot.ends.count, 2)
    }

    private func generatePromptVoice(
        service: TuringDialogueService,
        descriptor:
            TuringVoicePromptTriggerDescriptor,
        prerecording:
            TuringPrerecordingDescriptor
    ) async throws -> TuringVoicePromptPlan {
        try await service.generateVoicePrompt(
            VoicePromptRequest(
                id: descriptor.voicePromptID,
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
    }

    private func sha256(
        _ url: URL
    ) throws -> String {
        SHA256.hash(
            data: try Data(contentsOf: url)
        )
        .map {
            String(format: "%02x", $0)
        }
        .joined()
    }

    private func occurrenceCount(
        _ needle: String,
        in haystack: String
    ) -> Int {
        guard needle.isEmpty == false else {
            return 0
        }
        return haystack
            .components(separatedBy: needle)
            .count - 1
    }
}

private actor HamReceiverPromptCapturingRunner:
    TuringFoundationQueryRunning
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
              "text": "Copy that. I will repeat the verified information.",
              "emotion": "careful and direct"
            }
          ]
        }
        """
    }

    func lastPrompt() -> String? {
        prompt
    }
}

private actor HamReceiverBedSpy:
    TuringHamReceiverBedControlling
{
    struct Snapshot: Sendable {
        let beginOwnerIDs: [String]
        let endOwnerIDs: [String]
    }

    private var beginOwnerIDs: [String] = []
    private var endOwnerIDs: [String] = []

    func prepareResources() async throws {
    }

    func install(
        endpoint:
            any TuringAudioPlaybackEndpoint
    ) async {
    }

    func beginSession(
        ownerID: String
    ) async throws {
        beginOwnerIDs.append(ownerID)
    }

    func endSession(
        ownerID: String,
        reason _: String
    ) async {
        endOwnerIDs.append(ownerID)
    }

    func reset(reason _: String) async {
    }

    func unload(reason _: String) async {
    }

    func snapshot() -> Snapshot {
        Snapshot(
            beginOwnerIDs: beginOwnerIDs,
            endOwnerIDs: endOwnerIDs
        )
    }
}

private actor HamReceiverTuningSpy:
    TuringGeneratedGapBridge
{
    struct Begin: Sendable {
        let ownerID: String
        let waitingForSegmentIndex: Int
        let reason: String
    }

    struct End: Sendable {
        let ownerID: String
        let reason: String
    }

    struct Snapshot: Sendable {
        let begins: [Begin]
        let ends: [End]
    }

    private var begins: [Begin] = []
    private var ends: [End] = []

    func beginGap(
        ownerID: String,
        waitingForSegmentIndex: Int,
        reason: String
    ) async {
        begins.append(
            Begin(
                ownerID: ownerID,
                waitingForSegmentIndex:
                    waitingForSegmentIndex,
                reason: reason
            )
        )
    }

    func endGap(
        ownerID: String,
        reason: String
    ) async {
        ends.append(
            End(
                ownerID: ownerID,
                reason: reason
            )
        )
    }

    func reset(reason _: String) async {
    }

    func snapshot() -> Snapshot {
        Snapshot(
            begins: begins,
            ends: ends
        )
    }
}
