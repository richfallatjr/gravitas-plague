import Foundation
import XCTest

@testable import Gravitas_Plague

final class Chapter01FinalDadFrameTests: XCTestCase {
    private let scriptPointID = "chapter01.dadFrame.rich.script03"
    private let conversationKey = "chapter01.object.dad_frame.eulogy"

    func testFinalDadFrameUsesExistingDadPhotoSpeechPipeline() throws {
        let descriptor = try TuringFlowDescriptorStore().require(scriptPointID)
        XCTAssertEqual(descriptor.transmission.characterID, "rich")
        XCTAssertEqual(descriptor.transmission.outputRoute, .roomGlobal)
        XCTAssertEqual(
            descriptor.transmission.effectiveInteractionSurface,
            .dadFrame
        )
        XCTAssertEqual(
            descriptor.transmission.computeStart,
            .foundationBeforePrerecording
        )
        XCTAssertEqual(
            descriptor.transmission.fillerMode,
            .continuousFromPrerecordingToGenerated
        )
        XCTAssertFalse(descriptor.transmission.commSFX.openBeforePrerecording)
        XCTAssertFalse(descriptor.transmission.commSFX.sendAfterGenerated)
        XCTAssertEqual(
            descriptor.progression.interactionGateAfterCompletion,
            .microphone
        )
        XCTAssertEqual(descriptor.transmission.conversationKey, conversationKey)
        XCTAssertEqual(descriptor.transmission.backgroundMusic?.gainDB, -25)
    }

    func testFinalDadFrameAuthoredConversationContextIsIsolated() throws {
        let descriptor = try TuringFlowDescriptorStore().require(scriptPointID)
        let promptID = try XCTUnwrap(descriptor.transmission.voicePromptID)
        let prompt = try TuringVoicePromptTriggerStore().descriptor(id: promptID)
        let prerecording = try TuringPrerecordingStore().descriptor(
            id: descriptor.transmission.prerecordingID
        )

        XCTAssertEqual(prompt.characterProfileID, "rich.chapter01.dadEulogy")
        XCTAssertEqual(prompt.conversationKey, conversationKey)
        XCTAssertNil(prompt.promptContext)
        XCTAssertEqual(prompt.effectivePromptTemplateID, .roomObjectMemory)
        XCTAssertFalse(prerecording.transcript.isEmpty)
        XCTAssertEqual(prerecording.transcriptMode, .manual)
        XCTAssertEqual(prerecording.audioFile, "pr-rich-dad-frame-03.mp3")
    }

    func testFinalDadFrameBindingIsIndependentFromEarlierDadMemories() {
        let binding = TuringStorySurfaceFlowBinding.chapter01DadEulogyScript03
        XCTAssertEqual(binding.rootScriptPointID, scriptPointID)
        XCTAssertEqual(binding.terminalScriptPointID, scriptPointID)
        XCTAssertEqual(binding.conversationKey, conversationKey)
        XCTAssertNotEqual(
            binding.conversationKey,
            TuringStorySurfaceFlowBinding.chapter01FourChancesDad.conversationKey
        )
        XCTAssertNotEqual(
            binding.conversationKey,
            TuringStorySurfaceFlowBinding.prologueDadPhoto.conversationKey
        )
    }

    func testFinalDadFrameCheckpointsAreValidContinueTargets() {
        XCTAssertEqual(
            Chapter01Checkpoint.finalDadFramePending
                .supportedContinuationCheckpoint,
            .finalDadFramePending
        )
        XCTAssertEqual(
            Chapter01Checkpoint.complete.supportedContinuationCheckpoint,
            .complete
        )
    }

    func testFinalDadOnlyPolicyRejectsOtherSurfacesAndDoor() async throws {
        let arbiter = StoryInteractionArbiter()
        let transition = try await arbiter.claimStoryTransition(
            transitionID: UUID(),
            source: "test"
        )
        try await arbiter.setStableInteractionPolicy(
            .chapter01FinalDadFrameOnly,
            storyTransitionLease: transition,
            reason: "test"
        )
        await arbiter.updateTuringGates(
            [
                .dadFrame: .play,
                .walkie: .microphone,
                .hamReceiver: .microphone,
                .crankRadio: .play
            ],
            reason: "test"
        )
        await arbiter.release(transition, reason: "test")

        let snapshot = await arbiter.currentSnapshot()
        XCTAssertEqual(snapshot.dadFramePresentation, .play)
        XCTAssertEqual(snapshot.walkiePresentation, .hidden)
        XCTAssertEqual(snapshot.hamReceiverPresentation, .hidden)
        XCTAssertEqual(snapshot.crankRadioPresentation, .hidden)
        XCTAssertEqual(snapshot.doorPresentation, .hidden)
        XCTAssertEqual(snapshot.capabilities, [.dadFramePlay])
    }

    func testFinalDadReleaseReturnsTheAuthorizedPlaySnapshot() async throws {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGates(
            [
                .dadFrame: .play,
                .walkie: .closed,
                .hamReceiver: .closed,
                .crankRadio: .closed
            ],
            reason: "test"
        )
        let transition = try await arbiter.claimStoryTransition(
            transitionID: UUID(),
            source: "test"
        )
        try await arbiter.setStableInteractionPolicy(
            .chapter01FinalDadFrameOnly,
            storyTransitionLease: transition,
            reason: "test"
        )

        let snapshot = await arbiter.releaseAndCurrentSnapshot(
            transition,
            reason: "test"
        )

        XCTAssertNil(snapshot.exclusiveOwner)
        XCTAssertEqual(snapshot.doorState, .closedUnloaded)
        XCTAssertEqual(snapshot.dadFramePresentation, .play)
        XCTAssertEqual(snapshot.capabilities, [.dadFramePlay])
    }
}
